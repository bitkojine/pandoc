{-# LANGUAGE OverloadedStrings #-}
{- |
   Module      : Text.Pandoc.Readers.DocLang
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of DocLang XML to 'Pandoc' document.

See doc/doclang-implementation-plan.md before modifying this file.
-}
module Text.Pandoc.Readers.DocLang
  ( readDocLang
  ) where

import Control.Monad.Except (throwError)
import Data.Char (isSpace)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Map.Strict as M
import Text.Pandoc.Builder
import Text.Pandoc.Class.PandocMonad (PandocMonad)
import Text.Pandoc.Error (PandocError (..))
import Text.Pandoc.Options (ReaderOptions)
import Text.Pandoc.Sources (ToSources(..), sourcesToText)
import Text.Pandoc.XML.Light hiding (strContent, Attr, attrVal)

-- | Read DocLang XML and return a Pandoc document.
readDocLang :: (PandocMonad m, ToSources a)
            => ReaderOptions
            -> a
            -> m Pandoc
readDocLang _opts s = do
  let inp = sourcesToText (toSources s)
  let tree = parseXMLContents (TL.fromStrict inp)
  case tree of
    Left e  -> throwError $ PandocParseError
                 ("Could not parse DocLang XML: " <> T.pack (show e))
    Right [Elem doclang] -> parseDocLang doclang
    Right _ -> throwError $ PandocParseError
                 "DocLang document must have a single <doclang> root element"

-- | Parse the <doclang> root element.
parseDocLang :: PandocMonad m => Element -> m Pandoc
parseDocLang doclang = do
  let allContent = elContent doclang
  let (headEls, bodyEls) = partitionHead allContent
  meta <- case headEls of
           Just h -> parseHead h
           Nothing -> return mempty
  blocks <- mconcat <$> mapM parseTopLevel bodyEls
  return $ Pandoc meta (toList blocks)

-- | Separate optional <head> from body content.
partitionHead :: [Content] -> (Maybe Element, [Content])
partitionHead (Elem e : rest)
  | qName (elName e) == "head" = (Just e, rest)
partitionHead (Text (CData _ s _) : rest)
  | T.all isSpace s = partitionHead rest
partitionHead cs = (Nothing, cs)

-- | Parse metadata <head> element.
parseHead :: PandocMonad m => Element -> m Meta
parseHead headEl = do
  let childs = onlyElems $ elContent headEl
      metaMap = foldr addMetaField M.empty childs
  return $ Meta metaMap
  where
    addMetaField :: Element -> M.Map Text MetaValue -> M.Map Text MetaValue
    addMetaField e acc =
      let name = qName (elName e)
          textContent = T.strip $ strContent e
      in case name of
           "title" -> M.insert "title" (MetaInlines [Str textContent]) acc
           "author" -> case M.lookup "author" acc of
                         Just (MetaList items) ->
                           M.insert "author"
                             (MetaList (items ++ [MetaInlines [Str textContent]])) acc
                         _ -> M.insert "author"
                                (MetaList [MetaInlines [Str textContent]]) acc
           "date" -> M.insert "date" (MetaInlines [Str textContent]) acc
           "language" -> M.insert "lang" (MetaString textContent) acc
           _ -> M.insert name (MetaString textContent) acc

-- | Parse top-level elements (children of <doclang> or inside <text>).
parseTopLevel :: PandocMonad m => Content -> m Blocks
parseTopLevel (Elem e) = parseTopLevelElem e
parseTopLevel _ = return mempty

-- | Extract element head content (label, thread, etc.) from the beginning
-- of an element's content list. Returns kv-pairs and the remaining body.
extractHead :: [Content] -> ([(Text, Text)], [Content])
extractHead = go []
  where
    go kvs [] = (reverse kvs, [])
    go kvs (Text (CData _ s _) : rest)
      | T.all isSpace s = go kvs rest
    go kvs (c@(Text _) : rest) = (reverse kvs, c : rest)  -- non-space text: stop head
    go kvs (Elem e : rest) = case qName (elName e) of
      "label"  -> go (("label", fromMaybe "" (attrVal "value" e)) : kvs) rest
      "thread" -> go (("thread", fromMaybe "" (attrVal "thread_id" e)) : kvs) rest
      _        -> (reverse kvs, Elem e : rest)
    go kvs (_ : rest) = go kvs rest

parseTopLevelElem :: PandocMonad m => Element -> m Blocks
parseTopLevelElem e = case qName (elName e) of
  "text" -> do
    let (_, body) = extractHead $ elContent e
    content <- parseContent body
    return $ para (fromList content)
  "heading" -> do
    let lvl = maybe 1 (read . T.unpack) $ attrVal "level" e
    let (_, body) = extractHead $ elContent e
    content <- parseContent body
    return $ header lvl (fromList content)
  "code" -> do
    let (kvs, body) = extractHead $ elContent e
    let lang = lookup "label" kvs
    let codeContent = bodyContent body
    let langCls = case lang of Just l -> [l]; Nothing -> []
    return $ codeBlockWith ("", langCls, kvs) codeContent
  "formula" -> do
    let tex = T.strip $ strContent e
    return $ para (displayMath tex)
  "picture" -> do
    let srcUri = maybe "" id $ attrVal "uri" =<< filterChild (byName "src") e
    let picClass = maybe "" id $ attrVal "class" e
    let attrs = ("", [picClass | not (T.null picClass)], [])
    if T.null srcUri
      then return $ para (text "[image]")
      else return $ para (imageWith attrs srcUri "" (text srcUri))
  "list" -> do
    let ordered = attrVal "class" e == Just "ordered"
    items <- getListItems e
    if ordered
      then return $ orderedList (map fromList items)
      else return $ bulletList (map fromList items)
  "table" -> parseTable e
  "footnote" -> do
    content <- parseContent $ elContent e
    return $ para (note (plain (fromList content)))
  "page_break" -> return $ horizontalRule
  _ -> return mempty

-- | Get attribute value from an element.
attrVal :: Text -> Element -> Maybe Text
attrVal name e = lookupAttrBy (\qn -> qName qn == name) (elAttribs e)

-- | Parse content of a semantic element: text, formatting, and nested blocks.
parseContent :: PandocMonad m => [Content] -> m [Inline]
parseContent = fmap concat . mapM parseInlineContent

parseInlineContent :: PandocMonad m => Content -> m [Inline]
parseInlineContent (Text (CData _ s _)) =
  if T.all isSpace s then return [] else return [Str s]
parseInlineContent (Elem e) = parseInlineElement e
parseInlineContent _ = return []

parseInlineElement :: PandocMonad m => Element -> m [Inline]
parseInlineElement e = case qName (elName e) of
  "bold"          -> wrapInlines Strong e
  "italic"        -> wrapInlines Emph e
  "underline"     -> wrapInlines Underline e
  "strikethrough" -> wrapInlines Strikeout e
  "superscript"   -> wrapInlines Superscript e
  "subscript"     -> wrapInlines Subscript e
  "code"          -> return [Code nullAttr $ strContent e]
  "formula"       -> return [Math InlineMath $ T.strip $ strContent e]
  "content"       -> return [Str $ strContent e]
  "footnote"      -> parseFootnote e
  "href"          -> return []  -- element head property, handled at container level
  "label"         -> return []
  "location"      -> return []
  "caption"       -> return []
  _               -> return []

-- | Wrap element children in an inline constructor.
wrapInlines :: PandocMonad m => ([Inline] -> Inline) -> Element -> m [Inline]
wrapInlines ctor e = do
  children <- parseContent $ elContent e
  return [ctor children]

-- | Parse footnote inline element.
parseFootnote :: PandocMonad m => Element -> m [Inline]
parseFootnote e = do
  content <- parseContent $ elContent e
  return [Note [Plain content]]

-- | Get text content from element body, preferring <content> child.
bodyContent :: [Content] -> Text
bodyContent [] = ""
bodyContent (Elem e : _)
  | qName (elName e) == "content" = strContent e
bodyContent cs = T.concat [s | Text (CData _ s _) <- cs]

-- | Parse list items from a <list> element.
getListItems :: PandocMonad m => Element -> m [[Block]]
getListItems e = do
  let items = splitOnLdiv $ elContent e
  mapM parseListItem items

-- | Split list content into items at each <ldiv/> boundary.
splitOnLdiv :: [Content] -> [[Content]]
splitOnLdiv [] = []
splitOnLdiv cs =
  let (item, rest) = break isLdiv cs
  in case rest of
       (_:after) -> item : splitOnLdiv after
       []        -> if null item then [] else [item]

isLdiv :: Content -> Bool
isLdiv (Elem e) = qName (elName e) == "ldiv"
isLdiv _ = False

-- | Parse a single list item's content.
parseListItem :: PandocMonad m => [Content] -> m [Block]
parseListItem [] = return [Plain []]
parseListItem cs = do
  let blocks = mapMaybe elemToBlock cs
  if null blocks
    then do
      inlines <- parseContent cs
      return [Plain inlines]
    else return blocks

elemToBlock :: Content -> Maybe Block
elemToBlock (Elem e) = case qName (elName e) of
  "text"    -> Just $ Plain []  -- placeholder, handled by parseContent
  "list"    -> Nothing  -- nested lists handled separately
  "table"   -> Nothing
  _         -> Nothing
elemToBlock _ = Nothing

parseTable :: PandocMonad m => Element -> m Blocks
parseTable e = do
  let rows = collectTableCells $ elContent e
  let (headerRow, dataRows) = case rows of
        (r:rs) -> (r, rs)
        []     -> ([], [])
  let isHeader (OTSLHeader _) = True
      isHeader _ = False
  let hasHeaders = any isHeader headerRow
  let cellToBlocks (OTSLHeader bs) = bs
      cellToBlocks (OTSLData bs)   = bs
      cellToBlocks OTSLEmpty       = [Plain []]
  let headerBlks = if hasHeaders
                   then map (fromList . cellToBlocks) headerRow
                   else []
  let bodyBlks = map (map (fromList . cellToBlocks)) dataRows
  return $ simpleTable headerBlks bodyBlks

data OTSLCell = OTSLHeader [Block]
              | OTSLData   [Block]
              | OTSLEmpty

-- | Collect table cells from token sequence, grouped into rows.
collectTableCells :: [Content] -> [[OTSLCell]]
collectTableCells [] = []
collectTableCells cs = reverse . map reverse $ go [] cs
  where
    go acc [] = [acc | not (null acc)]
    go acc (Elem e : rest) = case qName (elName e) of
      "nl"   -> acc : go [] rest
      "ched" -> go (OTSLHeader (parseCellContent rest) : acc) (dropCellContent rest)
      "fcel" -> go (OTSLData (parseCellContent rest) : acc) (dropCellContent rest)
      "ecel" -> go (OTSLEmpty : acc) rest
      "srow" -> go (OTSLEmpty : acc) rest
      _      -> go acc rest
    go acc (_ : rest) = go acc rest

-- | Parse cell content up to the next OTSL token or element head element.
parseCellContent :: [Content] -> [Block]
parseCellContent [] = [Plain []]
parseCellContent (Elem e : _)
  | qName (elName e) `elem` ["fcel","ched","ecel","srow","nl",
                              "label","thread","href","xref","layer",
                              "location","caption","custom"] = [Plain []]
parseCellContent cs = 
  let (texts, _) = span isCellContent cs
      txt = T.concat [s | Text (CData _ s _) <- texts]
  in if T.all isSpace txt then [Plain []]
     else [Plain [Str $ T.strip txt]]

isCellContent :: Content -> Bool
isCellContent (Text _) = True
isCellContent (Elem e) = not $ qName (elName e) `elem`
  ["fcel","ched","ecel","srow","nl"]
isCellContent _ = True

-- | Drop cell content tokens up to the next OTSL token.
dropCellContent :: [Content] -> [Content]
dropCellContent [] = []
dropCellContent (c@(Elem e) : rest)
  | qName (elName e) `elem` ["fcel","ched","ecel","srow","nl"] = c : rest
dropCellContent (_ : rest) = dropCellContent rest

-- | Check if an element matches a tag name.
byName :: Text -> Element -> Bool
byName name e = qName (elName e) == name

-- | Extract the text content of an element (all text nodes concatenated).
strContent :: Element -> Text
strContent = T.concat . mapMaybe getText . elContent
  where
    getText (Text (CData _ s _)) = Just s
    getText _ = Nothing
