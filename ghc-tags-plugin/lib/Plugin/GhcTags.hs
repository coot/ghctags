{-# LANGUAGE CPP                 #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Plugin.GhcTags ( plugin, Options (..) ) where

import           Control.Exception
import           Control.Monad.State.Strict
import           Data.ByteString (ByteString)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Char8   as BSC
import qualified Data.ByteString.Lazy    as BSL
import qualified Data.ByteString.Builder as BB
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
#if __GLASGOW_HASKELL__ < 808
import           Data.Functor (void, (<$))
#endif
import           Data.Functor.Identity (Identity (..))
import           Data.List (sortBy)
#if __GLASGOW_HASKELL__ >= 810
import           Data.Either (partitionEithers)
#endif
import           Data.Foldable (traverse_)
import           Data.Maybe (mapMaybe)
import           System.Directory
import           System.FilePath
import           System.FilePath.ByteString (RawFilePath)
import qualified System.FilePath.ByteString as FilePath
import           System.IO

#if !defined(mingw32_HOST_OS)
import           Foreign.C.Types (CInt (..))
import           Foreign.C.Error (throwErrnoIfMinus1_)
import           GHC.IO.FD (FD (..))
import           GHC.IO.Handle.FD (handleToFd)
#endif

import           Options.Applicative.Types (ParserFailure (..))

import qualified Pipes as Pipes
import           Pipes.Safe (SafeT)
import qualified Pipes.Safe as Pipes.Safe
import qualified Pipes.ByteString as Pipes.BS

#if __GLASGOW_HASKELL__ >= 900
import           GHC.Driver.Plugins
#else
import           GhcPlugins
#endif
                            ( CommandLineOption
                            , Plugin (..)
                            )
#if __GLASGOW_HASKELL__ >= 900
import qualified GHC.Driver.Plugins as GhcPlugins
import           GHC.Driver.Types ( Hsc
                                  , HsParsedModule (..)
                                  , ModSummary (..)
                                  , MetaHook
                                  , MetaRequest (..)
                                  , MetaResult
                                  , metaRequestAW
                                  , metaRequestD
                                  , metaRequestE
                                  , metaRequestP
                                  , metaRequestT
                                  )
import           GHC.Driver.Hooks (Hooks (..))
import           GHC.Unit.Types   (Module)
import           GHC.Unit.Module.Location   (ModLocation (..))
import           GHC.Tc.Types (TcM)
import           GHC.Tc.Gen.Splice (defaultRunMeta)
import           GHC.Types.SrcLoc (Located)
#else
import qualified GhcPlugins
import           GhcPlugins ( Hsc
                            , HsParsedModule (..)
                            , Located
                            , Module
                            , ModLocation (..)
                            , ModSummary (..)
#if __GLASGOW_HASKELL__ >= 810
                            , MetaHook
                            , MetaRequest (..)
                            , MetaResult
                            , metaRequestAW
                            , metaRequestD
                            , metaRequestE
                            , metaRequestP
                            , metaRequestT
#endif
                            )
#endif
#if   __GLASGOW_HASKELL__ >= 900
import           GHC.Driver.Session (DynFlags (hooks))
#elif __GLASGOW_HASKELL__ >= 810
import           DynFlags (DynFlags (hooks))
#else
import           DynFlags (DynFlags)
#endif

#if   __GLASGOW_HASKELL__ >= 900
import           GHC.Hs (GhcPs, GhcTc, HsModule (..), LHsDecl, LHsExpr)
#elif __GLASGOW_HASKELL__ >= 810
import           GHC.Hs (GhcPs, GhcTc, HsModule (..), LHsDecl, LHsExpr)
import           TcSplice
import           TcRnMonad
import           Hooks
#else
import           HsExtension (GhcPs)
import           HsSyn (HsModule (..))
#endif
#if __GLASGOW_HASKELL__ >= 900
import           GHC.Utils.Outputable (($+$), ($$))
import qualified GHC.Utils.Outputable as Out
import qualified GHC.Utils.Ppr.Colour as PprColour
#else
import           Outputable (($+$), ($$))
import qualified Outputable as Out
import qualified PprColour
#endif

import           GhcTags.Ghc
import           GhcTags.Tag
import           GhcTags.Stream
import qualified GhcTags.CTag as CTag
import qualified GhcTags.ETag as ETag

import           Plugin.GhcTags.Options
import           Plugin.GhcTags.FileLock
import qualified Plugin.GhcTags.CTag as CTag


#if   __GLASGOW_HASKELL__ >= 900
type GhcPsModule = HsModule
#else
type GhcPsModule = HsModule GhcPs
#endif


-- | The GhcTags plugin.  It will run for every compiled module and have access
-- to parsed syntax tree.  It will inspect it and:
--
-- * update a global mutable state variable, which stores a tag map.
--   It is shared across modules compiled in the same `ghc` run.
-- * update 'tags' file.
--
-- The global mutable variable save us from parsing the tags file for every
-- compiled module.
--
-- __The syntax tree is left unchanged.__
--
-- The tags file will contain location information about:
--
--  * /top level terms/
--  * /data types/
--  * /record fields/
--  * /type synonyms/
--  * /type classes/
--  * /type class members/
--  * /type class instances/
--  * /type families/                           /(standalone and associated)/
--  * /type family instances/                   /(standalone and associated)/
--  * /data type families/                      /(standalone and associated)/
--  * /data type families instances/            /(standalone and associated)/
--  * /data type family instances constructors/ /(standalone and associated)/
--
plugin :: Plugin
plugin = GhcPlugins.defaultPlugin {
      parsedResultAction = ghcTagsParserPlugin,
#if __GLASGOW_HASKELL__ >= 810
      dynflagsPlugin     = ghcTagsDynflagsPlugin,
#endif
      pluginRecompile    = GhcPlugins.purePlugin
   }


-- | IOExcption wrapper; it is useful for the user to know that it's the plugin
-- not `ghc` that thrown the error.
--
data GhcTagsPluginException
    = GhcTagsParserPluginIOException IOException
    | GhcTagsDynFlagsPluginIOException IOException
    deriving Show

instance Exception GhcTagsPluginException


-- | The plugin does not change the 'HsParedModule', it only runs side effects.
--
ghcTagsParserPlugin :: [CommandLineOption] -> ModSummary -> HsParsedModule -> Hsc HsParsedModule
ghcTagsParserPlugin options
                    moduleSummary@ModSummary {ms_mod, ms_hspp_opts = dynFlags}
                    hsParsedModule@HsParsedModule {hpm_module} =

    hsParsedModule <$
      case runOptionParser options of
        Success opts@Options { filePath = Identity tagsFile
                             , debug
                             } ->

           liftIO $ do
            let sourceFile = case splitFileName tagsFile of
                  (dir, name) -> dir </> "." ++ name
                lockFile = sourceFile ++ ".lock"

            -- wrap 'IOException's
            handle (\ioerr -> do
                     putDocLn dynFlags
                              (messageDoc UnhandledException (Just ms_mod)
                                (displayException ioerr))
                     throwIO (GhcTagsParserPluginIOException ioerr)) $
             flip finally (void $ try @IOException $ removeFile sourceFile) $
                -- Take advisory exclusive lock (a BSD lock using `flock`) on the tags
                -- file.  This is needed when `cabal` compiles in parallel.
                -- We take the lock on the copy, otherwise the lock would be removed when
                -- we move the file.
                withFileLock lockFile ExclusiveLock $ \_ -> do
                    mbInSize <-
                      if debug
                        then Just <$> getFileSize tagsFile
                                      `catch` \(_ :: IOException) -> pure 0
                        else pure Nothing
                    updateTags opts moduleSummary hpm_module sourceFile
                    when debug $ do
                      let Just inSize = mbInSize
                      outSize <- getFileSize tagsFile
                      when (inSize > outSize)
                        $ throwIO (userError $ concat
                                    [ "tags file '"
                                    , tagsFile
                                    , "' size shrinked: "
                                    , show inSize
                                    , "→"
                                    , show outSize
                                    ])

        Failure (ParserFailure f)  ->
          liftIO $
            putDocLn dynFlags
                     (messageDoc
                       OptionParserFailure
                       (Just ms_mod)
                       (show (case f "<ghc-tags-plugin>" of (h, _, _) -> h)
                         ++ " " ++ show options))

        CompletionInvoked {} -> error "ghc-tags-plugin: impossible happend"


data MessageType =
      ReadException
    | ParserException
    | WriteException
    | UnhandledException
    | OptionParserFailure
    | DebugMessage


instance Show MessageType where
    show ReadException       = "read error"
    show ParserException     = "tags parser error"
    show WriteException      = "write error"
    show UnhandledException  = "unhandled error"
    show OptionParserFailure = "plugin options parser error"
    show DebugMessage        = ""


-- | Extract tags from a module and update tags file
--
updateTags :: Options Identity
           -> ModSummary
           -> Located GhcPsModule
           -> FilePath
           -> IO ()
updateTags Options { etags, filePath = Identity tagsFile, debug }
           ModSummary {ms_mod, ms_location, ms_hspp_opts = dynFlags}
           lmodule sourceFile = do
  tagsFileExists <- doesFileExist tagsFile
  when tagsFileExists
    $ renameFile tagsFile sourceFile
  withFile tagsFile WriteMode  $ \writeHandle ->
    withFile sourceFile ReadWriteMode $ \readHandle -> do
      cwd <- BSC.pack <$> getCurrentDirectory
      -- absolute directory path of the tags file; we need canonical path
      -- (without ".." and ".") to make 'makeRelative' works.
      tagsDir <- BSC.pack <$> canonicalizePath (fst $ splitFileName tagsFile)

      case (etags, ml_hs_file ms_location) of

        --
        -- ctags
        --
        (False, Nothing)          -> pure ()
        (False, Just sourcePath) -> do

          let sourcePathBS = Text.encodeUtf8 (Text.pack sourcePath)
              -- text parser
              producer :: Pipes.Producer ByteString (SafeT IO) ()
              producer
                | tagsFileExists =
                    void (Pipes.BS.fromHandle readHandle)
                    `Pipes.Safe.catchP` \(e :: IOException) ->
                      Pipes.lift $ Pipes.liftIO $
                        -- don't re-throw; this would kill `ghc`, error
                        -- loudly and continue.
                        putDocLn dynFlags (messageDoc ReadException (Just ms_mod) (displayException e))
                | otherwise      = pure ()

              -- tags pipe
              pipe :: Pipes.Effect (StateT Int (StateT [CTag] (SafeT IO))) ()
              pipe =
                Pipes.for
                  (Pipes.hoist Pipes.lift $ Pipes.hoist Pipes.lift (tagParser (either (const Nothing) Just <$> CTag.parseTagLine) producer)
                    `Pipes.Safe.catchP` \(e :: IOException) ->
                      Pipes.lift $ Pipes.liftIO $
                        -- don't re-throw; this would kill `ghc`, error
                        -- loudly and continue.
                        putDocLn dynFlags $ messageDoc ParserException (Just ms_mod) (displayException e)
                  )
                  $
                  -- merge tags
                  (\tag -> do
                    modify' succ
                    Pipes.hoist Pipes.lift $
                        runCombineTagsPipe writeHandle
                          CTag.compareTags
                          CTag.formatTag
                          (fixFilePath cwd tagsDir sourcePathBS)
                          tag
                      `Pipes.Safe.catchP` \(e :: IOException) ->
                        Pipes.lift $ Pipes.liftIO $
                          -- don't re-throw; this would kill `ghc`, error
                          -- loudly and continue.
                          putDocLn dynFlags $ messageDoc WriteException (Just ms_mod) (displayException e)
                  )

          let tags :: [CTag]
              tags = map (fixTagFilePath cwd tagsDir)
                                          -- fix file names
                   . filterAdjacentTags
                   . sortBy compareTags   -- sort
                   . mapMaybe (ghcTagToTag SingCTag dynFlags)
                                          -- translate 'GhcTag' to 'Tag'
                   . getGhcTags           -- generate 'GhcTag's
                   $ lmodule

          -- Write header
          BSL.hPut writeHandle (BB.toLazyByteString (foldMap CTag.formatHeader CTag.headers))
          -- update tags file / run 'pipe'
          (parsedTags, tags') <- Pipes.Safe.runSafeT $ runStateT (execStateT (Pipes.runEffect pipe) 0) tags
          -- write the remaining tags'
          traverse_ (BSL.hPut writeHandle . BB.toLazyByteString . CTag.formatTag) tags'

          hFlush writeHandle
          -- hDataSync is necessary, otherwise next read will not get all the
          -- data, and the tags file will get truncated. Issue #37.
          hDataSync writeHandle

          when debug
            $ printMessageDoc dynFlags DebugMessage (Just ms_mod)
                (concat [ "parsed: "
                        , show parsedTags
                        , " found: "
                        , show (length tags)
                        , " left: "
                        , show (length tags')
                        ])

        --
        -- etags
        --
        (True, Nothing)         -> pure ()
        (True, Just sourcePath) ->
          try @IOException (BS.hGetContents readHandle)
            >>= \case
              Left err ->
                putDocLn dynFlags $ messageDoc ReadException (Just ms_mod) (displayException err)

              Right txt -> do
                pres <- try @IOException $ ETag.parseTagsFile txt
                case pres of
                  Left err   ->
                    putDocLn dynFlags $ messageDoc ParserException (Just ms_mod) (displayException err)

                  Right (Left err) ->
                    printMessageDoc dynFlags ParserException (Just ms_mod) err

                  Right (Right tags) -> do
                    let sourcePathBS = Text.encodeUtf8 (Text.pack sourcePath)

                        newTags  :: [ETag]
                        newTags =
                            filterAdjacentTags
                          . sortBy ETag.compareTags
                          . map (fixTagFilePath cwd tagsDir)
                          . mapMaybe (ghcTagToTag SingETag dynFlags)
                          . getGhcTags
                          $ lmodule

                        tags' :: [ETag]
                        tags' = combineTags
                                  ETag.compareTags
                                  (fixFilePath cwd tagsDir sourcePathBS)
                                  newTags
                                  (sortBy ETag.compareTags tags)

                    when debug
                      $ printMessageDoc dynFlags DebugMessage (Just ms_mod)
                          (concat [ "parsed: "
                                  , show (length tags)
                                  , " found: "
                                  , show (length newTags)
                                  ])

                    BB.hPutBuilder writeHandle (ETag.formatETagsFile tags')


-- | Filter adjacent tags.
--
filterAdjacentTags :: [Tag tk] -> [Tag tk]
filterAdjacentTags tags =
    foldr
      (\(mprev, c, mnext) acc ->
          case (mprev, mnext) of
            -- filter out terms preceded by a type signature
            (Just p, _)  | tagName p == tagName c
                         , TkTypeSignature <- tagKind p
                         , k <- tagKind c
                         , k == TkTerm
                        || k == TkFunction
                        ->     acc

            -- filter out type constructors followed by a data constructor
            (_, Just n)  | tagName c == tagName n
                         , TkTypeConstructor <- tagKind c
                         , k <- tagKind n
                         , k == TkDataConstructor
                        || k == TkGADTConstructor
                        ->     acc

            _           -> c : acc
                       
      )
      []
      (zip3 tags' tags tags'')
  where
    -- previous
    tags' = case tags of
      [] -> []
      _  -> Nothing : map Just (init tags)

    -- next
    tags'' = case tags of
      [] -> []
      _  -> map Just (tail tags) ++ [Nothing]


#if __GLASGOW_HASKELL__ >= 810
--
-- Tags for Template-Haskell splices
--

-- | DynFlags plugin which extract tags from TH splices.
--
ghcTagsDynflagsPlugin :: [CommandLineOption] -> DynFlags -> IO DynFlags
ghcTagsDynflagsPlugin options dynFlags =
    pure dynFlags
      { hooks =
          (hooks dynFlags)
            { runMetaHook = Just ghcTagsMetaHook }
      }
  where
    ghcTagsMetaHook :: MetaHook TcM
    ghcTagsMetaHook request expr =
      case runOptionParser options of
        Success Options { filePath = Identity tagsFile
                        , etags
                        } -> do
          let sourceFile = case splitFileName tagsFile of
                (dir, name) -> dir </> "." ++ name
              lockFile = sourceFile ++ ".lock"

          withMetaD defaultRunMeta request expr $ \decls ->
            liftIO $
              handle (\ioerr -> do
                       putDocLn dynFlags
                               (messageDoc UnhandledException Nothing
                                 (displayException ioerr))
                       throwIO (GhcTagsDynFlagsPluginIOException ioerr)) $
              withFileLock lockFile ExclusiveLock $ \_ -> do
              cwd <- BSC.pack <$> getCurrentDirectory
              tagsDir <- BSC.pack <$> canonicalizePath (fst $ splitFileName tagsFile)
              tagsContent <- BSC.readFile tagsFile
              if etags
                then do
                  pr <- ETag.parseTagsFile tagsContent
                  case pr of
                    Left err ->
                      printMessageDoc dynFlags ParserException Nothing err

                    Right tags -> do
                      let tags' :: [ETag]
                          tags' = sortBy ETag.compareTags $
                                    tags
                                    ++
                                    (fmap (fixTagFilePath  cwd tagsDir)
                                    . ghcTagToTag SingETag dynFlags)
                                      `mapMaybe`
                                       hsDeclsToGhcTags Nothing decls
                      BSL.writeFile tagsFile (BB.toLazyByteString $ ETag.formatTagsFile tags')
                else do
                  pr <- fmap partitionEithers <$> CTag.parseTagsFile tagsContent
                  case pr of
                    Left err ->
                      printMessageDoc dynFlags ParserException Nothing err

                    Right (headers, tags) -> do
                      let tags' :: [Either CTag.Header CTag]
                          tags' = Left `map` headers
                               ++ Right `map`
                                  sortBy CTag.compareTags
                                  ( tags
                                    ++
                                    (fmap (fixTagFilePath  cwd tagsDir)
                                      . ghcTagToTag SingCTag dynFlags)
                                      `mapMaybe`
                                      hsDeclsToGhcTags Nothing decls
                                  )
                      BSL.writeFile tagsFile (BB.toLazyByteString $ CTag.formatTagsFile tags')

        Failure (ParserFailure f)  ->
          withMetaD defaultRunMeta request expr $ \_ ->
          liftIO $
            putDocLn dynFlags
                     (messageDoc
                       OptionParserFailure
                       Nothing
                       (show (case f "<ghc-tags-plugin>" of (h, _, _) -> h)
                         ++ " " ++ show options))

        CompletionInvoked {} -> error "ghc-tags-plugin: impossible happend"

    -- run the hook and call call the callback with new declarations
    withMetaD :: MetaHook TcM -> MetaRequest -> LHsExpr GhcTc
                    -> ([LHsDecl GhcPs] -> TcM a)
                    -> TcM (MetaResult)
    withMetaD h req e f = case req of
      MetaE  k -> k <$> metaRequestE h e
      MetaP  k -> k <$> metaRequestP h e
      MetaT  k -> k <$> metaRequestT h e
      MetaD  k -> do
        res <- metaRequestD h e
        k res <$ f res
      MetaAW k -> k <$> metaRequestAW h e
#endif


--
-- File path utils
--

fixFilePath :: RawFilePath
            -- ^ curent directory
            -> RawFilePath
            -- ^ tags file directory
            -> RawFilePath
            -- ^ tag's file path
            -> RawFilePath
fixFilePath cwd tagsDir =
    FilePath.normalise
  . FilePath.makeRelative tagsDir
  . (cwd FilePath.</>)


-- we are missing `Text` based `FilePath` library!
fixTagFilePath :: RawFilePath
               -- ^ current directory
               -> RawFilePath
               -- ^ tags file directory
               -> Tag tk -> Tag tk
fixTagFilePath cwd tagsDir tag@Tag { tagFilePath = TagFilePath fp } =
  tag { tagFilePath =
          TagFilePath
            (Text.decodeUtf8
              (fixFilePath cwd tagsDir
                (Text.encodeUtf8 fp)))
      }

--
-- Error Formattng
--

data MessageSeverity
      = Debug
      | Warning
      | Error

messageDoc :: MessageType -> Maybe Module -> String -> Out.SDoc
messageDoc errorType mb_mod errorMessage =
    Out.blankLine
      $+$
        Out.coloured PprColour.colBold
          ((Out.text "GhcTagsPlugin: ")
            Out.<> (Out.coloured messageColour (Out.text $ show errorType)))
      $$
        case mb_mod of
          Just mod_ ->
            Out.coloured PprColour.colBold (Out.nest 4 $ Out.ppr mod_)
          Nothing -> Out.empty
      $$
        (Out.nest 8 $ Out.coloured messageColour (Out.text errorMessage))
      $+$
        Out.blankLine
      $+$ case severity of
        Error ->
          Out.coloured PprColour.colBold (Out.text "Please report this bug to: ")
            Out.<> Out.text "https://github.com/coot/ghc-tags-plugin/issues"
          $+$ Out.blankLine
        Warning -> Out.blankLine
        Debug -> Out.blankLine
  where
    severity = case errorType of
      ReadException       -> Error
      ParserException     -> Error
      WriteException      -> Error
      UnhandledException  -> Error
      OptionParserFailure -> Warning
      DebugMessage        -> Debug

    messageColour = case severity of
      Error   -> PprColour.colRedFg
      Warning -> PprColour.colBlueFg
      Debug   -> PprColour.colCyanFg


putDocLn :: DynFlags -> Out.SDoc -> IO ()
putDocLn dynFlags sdoc =
    putStrLn $
#if __GLASGOW_HASKELL__ >= 900
      Out.renderWithStyle
        (Out.initSDocContext
          dynFlags
          (Out.setStyleColoured False
            $ Out.mkErrStyle Out.neverQualify))
        sdoc
#else
      Out.renderWithStyle
        dynFlags
        sdoc
        (Out.setStyleColoured True $ Out.defaultErrStyle dynFlags)
#endif


printMessageDoc :: DynFlags -> MessageType -> Maybe Module -> String -> IO ()
printMessageDoc dynFlags = (fmap . fmap . fmap) (putDocLn dynFlags) messageDoc

--
-- Syscalls
--

#if !defined(mingw32_HOST_OS)
hDataSync ::  Handle -> IO ()
hDataSync h = do
    FD { fdFD } <- handleToFd h
    throwErrnoIfMinus1_ "ghc-tags-plugin" (c_fdatasync fdFD)

foreign import ccall safe "fdatasync"
    c_fdatasync :: CInt -> IO CInt
#else
hDataSync :: Handle -> IO ()
hDataSync _ = pure ()
#endif
