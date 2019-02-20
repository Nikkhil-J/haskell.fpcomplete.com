{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
module Docs
  ( Docs (..)
  , Page (..)
  , PageHtml
  , getDocLoader
  ) where

import ClassyPrelude.Yesod hiding (Source, pageTitle, pageBody)
import System.FilePath
import CMarkGFM
import Text.Blaze.Html (preEscapedToHtml)
import Network.HTTP.Simple
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.Text.Encoding (decodeUtf8')
import Data.Yaml
import Control.AutoUpdate

data Page body = Page
  { pageTitle :: !Html
  , pageDescription :: !(Maybe Text)
  , pageAuthor :: !(Maybe Text)
  , pageHead :: !Html
  , pageBody :: !body
  , pageSkipH1 :: !Bool
  , pageEditLink :: !(Maybe Text)
  }

-- | Wrap in IO so that remote content can be downloaded on demand
type PageHtml = Page (IO Html)

-- | Body is URL containing the raw Markdown
instance body ~ Maybe String => FromJSON (Page body) where
  parseJSON = withObject "Page" $ \o -> do
    pageTitle <- (toHtml :: Text -> Html) <$> (o .: "title")
    pageDescription <- o .:? "description"
    pageAuthor <- o .:? "author"
    pageHead <- (fmap (preEscapedToHtml :: Text -> Html) <$> (o .:? "head")) .!= ""
    pageSkipH1 <- o .:? "skip-h1" .!= False
    pageBody <- o .:? "url"
    let pageEditLink = Nothing
    pure Page {..}

data Docs = Docs
  { docsLibraries :: !(Map Text PageHtml)
  , docsTutorials :: !(Map Text PageHtml)
  , docsPages :: !(Map Text PageHtml)
  }
instance Semigroup Docs where
  Docs x1 x2 x3 <> Docs y1 y2 y3 = Docs (x1 <> y1) (x2 <> y2) (x3 <> y3)
instance Monoid Docs where
  mempty = Docs mempty mempty mempty

loadDocs :: IO Docs
loadDocs = runConduitRes $ src .| foldC
  where
    src = tutorials >> pages

    tutorials = sourceDirectoryDeep True "tutorials" .| mapMC toDocs
    pages = sourceDirectoryDeep True "pages" .|
            filterC (\fp -> takeExtension fp == ".md") .|
            mapMC (\fp -> liftIO $ do
                      page <- getMarkdownDoc fp
                      pure $ Docs mempty mempty $ singletonMap
                        (fromString $ takeBaseName fp)
                        page)

toDocs :: MonadIO m => FilePath -> m Docs
toDocs fp = liftIO $
  case splitExtension $ takeFileName fp of
    (name, ".md") -> byName name <$> getMarkdownDoc fp
    (name, ".yaml") -> byName name <$> getYamlDoc fp
    _ -> pure mempty
  where
    byName (fromString -> name) page =
      case stripPrefix "package-" name of
        Just lib ->
          let page' = page { pageTitle = pageTitle page <> " - the " <> toHtml lib <> " library" }
           in Docs (singletonMap lib page') mempty mempty
        Nothing -> Docs mempty (singletonMap name page) mempty

renderMarkdown :: ByteString -> IO Html
renderMarkdown bodyBS = do
  bodyText <- either throwIO pure $ decodeUtf8' bodyBS
  pure $ preEscapedToHtml $ commonmarkToHtml
    [ optSmart
    , optUnsafe
    ]
    [ extStrikethrough
    , extTable
    , extAutolink
    ]
    bodyText

getMarkdownDoc :: FilePath -> IO PageHtml
getMarkdownDoc fp = handleAny onErr $ do
  bs <- B.readFile fp
  (frontmatterBS, bodyBS) <- maybe (error "No frontmatter found") pure $ do
    "---":ls <- Just $ B8.lines bs
    (fm, "---":body) <- Just $ break (== "---") ls
    Just (B8.unlines fm, B8.unlines body)
  page0 <- decodeThrow frontmatterBS
  for_ (pageBody page0) $ \url ->
    error $ "Should not have a URL: " ++ show url
  body <- renderMarkdown bodyBS
  pure page0
    { pageBody = pure body
    , pageEditLink =
        Just $
        "https://github.com/fpco/haskell.fpcomplete.com/blob/master/" <>
        fromString fp
    }
  where
    onErr e = error $ concat
      [ "Couldn't load Markdown page "
      , show fp
      , ": "
      , show e
      ]

getYamlDoc :: FilePath -> IO PageHtml
getYamlDoc fp = handleAny onErr $ do
  page0 <- decodeFileThrow fp
  req <-
    case pageBody page0 of
      Nothing -> error "Must provide a URL"
      Just url -> parseRequestThrow url
  getter <- mkAutoUpdate defaultUpdateSettings
    { updateFreq = 5 * 60 * 1000 * 1000
    , updateAction =
        handleAny onErr $
        httpBS req >>=
        renderMarkdown . dropFirstHeading . getResponseBody
    }
  pure page0
    { pageBody = getter
    }
      -- htmlText <- parseRequestThrow url >>= httpBS >>= renderMarkdown
    {-
  text <- readFileUtf8 fp
  case T.lines text of
    [title, url] -> do
      req <- parseRequest $ T.unpack url
      markdownText <- fmap mconcat $ httpSink req $ const $ decodeUtf8C .| sinkList
      let htmlText = commonmarkToHtml
            [optSmart, optUnsafe]
            [extStrikethrough, extTable, extAutolink]
            markdownText
      pure Doc
        { docTitle = toHtml title
        , docBody =
            case extractH1 htmlText of
              [] -> h1 (toHtml title) <> preEscapedToHtml htmlText
              _ -> preEscapedToHtml htmlText
        , docEditLink = Nothing
        }
    _ -> error $ "Malformed file: " ++ show fp
    -}
  where
    onErr :: SomeException -> IO a
    onErr e = error $ concat
      [ "Couldn't load YAML page "
      , show fp
      , ": "
      , show e
      ]

    dropFirstHeading bs
      | "#" `B.isPrefixOf` bs = B.drop 1 $ B.dropWhile (/= 10) bs
      | otherwise = bs

getDocLoader
  :: Bool -- ^ dev mode: reload on each page load
  -> IO (IO Docs)
getDocLoader True = pure loadDocs
getDocLoader False = do
  docs <- loadDocs
  pure $ pure docs
