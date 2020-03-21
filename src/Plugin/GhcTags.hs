{-# LANGUAGE CPP                 #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Plugin.GhcTags ( plugin ) where

import           Control.Exception
import           Control.Monad.State.Strict
import qualified Data.ByteString.Lazy    as BSL
import qualified Data.ByteString.Builder as BB
#if __GLASGOW_HASKELL__ < 808
import           Data.Functor (void, (<$))
#endif
import           Data.List (sortBy)
import           Data.Foldable (traverse_)
import           Data.Maybe (mapMaybe)
import           Data.Text (Text)
import           System.Directory
import           System.FilePath
import           System.IO

import qualified Pipes as Pipes
import           Pipes.Safe (SafeT)
import qualified Pipes.Safe as Pipes.Safe
import qualified Pipes.ByteString as Pipes.BS
import qualified Pipes.Text.Encoding as Pipes.Text

import           GhcPlugins ( CommandLineOption
                            , Hsc
                            , HsParsedModule (..)
                            , Located
                            , ModSummary (..)
                            , Plugin (..)
                            )
import qualified GhcPlugins
import           HsExtension (GhcPs)
import           HsSyn (HsModule (..))
import qualified Outputable as Out
import qualified PprColour

import           Plugin.GhcTags.Generate
import           Plugin.GhcTags.Tag
import           Plugin.GhcTags.Stream
import qualified Plugin.GhcTags.CTags as CTags
import           Plugin.GhcTags.Utils


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
--  * top level terms
--  * data types
--  * record fields
--  * type synonyms
--  * type classes
--  * type class members
--  * type class instances
--  * type families                           /(standalone and associated)/
--  * type family instances                   /(standalone and associated)/
--  * data type families                      /(standalone and associated)/
--  * data type families instances            /(standalone and associated)/
--  * data type family instances constructors /(standalone and associated)/
--
plugin :: Plugin
plugin = GhcPlugins.defaultPlugin {
      parsedResultAction = ghcTagsPlugin,
      pluginRecompile    = GhcPlugins.purePlugin
   }


-- | IOExcption wrapper; it is useful for the user to know that it's the plugin
-- not `ghc` that thrown the error.
--
data GhcTagsPluginException =
      GhcTagsPluginIOExceptino IOException
    deriving Show

instance Exception GhcTagsPluginException


-- | The plugin does not change the 'HsParedModule', it only runs side effects.
--
ghcTagsPlugin :: [CommandLineOption] -> ModSummary -> HsParsedModule -> Hsc HsParsedModule
ghcTagsPlugin options moduleSummary hsParsedModule@HsParsedModule {hpm_module} =
    hsParsedModule <$ GhcPlugins.liftIO (updateTags moduleSummary tagsFile hpm_module)
  where
    tagsFile :: FilePath
    tagsFile = case options of
      []    -> "tags"
      a : _ -> a

data ExceptionType =
      ReadException
    | ParserExectpion
    | WriteException
    | UnhandledException

instance Show ExceptionType where
    show ReadException      = "read error"
    show ParserExectpion    = "parser error"
    show WriteException     = "write error"
    show UnhandledException = "unhandled error"

-- | Extract tags from a module and update tags file
--
updateTags :: ModSummary
           -> FilePath
           -> Located (HsModule GhcPs)
           -> IO ()
updateTags ModSummary {ms_mod, ms_hspp_opts = dynFlags} tagsFile lmodule =
    -- wrap 'IOException's
    handle (\ioerr -> do
           putDocLn (errorDoc UnhandledException (displayException ioerr))
           throwIO $ GhcTagsPluginIOExceptino ioerr) $
    flip finally (void $ try @IOException $ removeFile sourceFile) $
      -- Take advisory exclusive lock (a BSD lock using `flock`) on the tags
      -- file.  This is needed when `cabal` compiles in parallel.
      -- We take the lock on the copy, otherwise the lock would be removed when
      -- we move the file.
      withFileLock lockFile ExclusiveLock WriteMode $ \_ -> do
        tagsFileExists <- doesFileExist tagsFile
        when tagsFileExists
          $ renameFile tagsFile sourceFile
        withFile tagsFile WriteMode  $ \writeHandle ->
          withFile sourceFile ReadWriteMode $ \readHandle -> do
            let -- text parser
                producer :: Pipes.Producer Text (SafeT IO) ()
                producer
                  | tagsFileExists =
                      void (Pipes.Text.decodeUtf8
                             (Pipes.BS.fromHandle readHandle))
                      `Pipes.Safe.catchP` \(e :: IOException) ->
                        Pipes.lift $ Pipes.liftIO $
                          -- don't re-throw; this would kill `ghc`, error
                          -- loudly and continue.
                          putDocLn (errorDoc ReadException (displayException e))
                  | otherwise      = pure ()

                -- gags pipe
                pipe :: Pipes.Effect (StateT [CTag] (SafeT IO)) ()
                pipe =
                  Pipes.for
                    (Pipes.hoist Pipes.lift (tagParser CTags.parseTagLine producer)
                      `Pipes.Safe.catchP` \(e :: IOException) ->
                        Pipes.lift $ Pipes.liftIO $
                          -- don't re-throw; this would kill `ghc`, error
                          -- loudly and continue.
                          putDocLn $ errorDoc ParserExectpion (displayException e)
                    )
                    (\tag ->
                      runCombineTagsPipe writeHandle CTags.formatTag tag
                        `Pipes.Safe.catchP` \(e :: IOException) ->
                          Pipes.lift $ Pipes.liftIO $
                            -- don't re-throw; this would kill `ghc`, error
                            -- loudly and continue.
                            putDocLn $ errorDoc WriteException (displayException e)
                    )

            cwd <- getCurrentDirectory
            -- absolute directory path of the tags file; we need canonical path
            -- (without ".." and ".") to make 'makeRelative' works.
            tagsDir <- canonicalizePath (fst $ splitFileName tagsFile)

            let tags :: [CTag]
                tags = map (fixFileName cwd tagsDir)
                                            -- fix file names
                     . sortBy compareTags   -- sort
                     . mapMaybe (ghcTagToTag SingCTag)
                                            -- translate 'GhcTag' to 'Tag'
                     . getGhcTags           -- generate 'GhcTag's
                     $ lmodule

            -- Write header
            BSL.hPut writeHandle (BB.toLazyByteString (CTags.formatHeaders))
            -- update tags file / run 'pipe'
            tags' <- Pipes.Safe.runSafeT $ execStateT ((Pipes.runEffect pipe)) tags
            -- write the remaining tags'
            traverse_ (BSL.hPut writeHandle . BB.toLazyByteString . CTags.formatTag) tags'

  where

    sourceFile = case splitFileName tagsFile of
      (dir, name) -> dir </> "." ++ name
    lockFile = sourceFile ++ ".lock"

    fixFileName :: FilePath -> FilePath -> Tag tk -> Tag tk
    fixFileName cwd tagsDir tag@Tag { tagFile = TagFile path } =
      tag { tagFile = TagFile (makeRelative tagsDir (cwd </> path)) }

    errorDoc :: ExceptionType -> String -> Out.SDoc
    errorDoc errorType errorMessage =
      Out.coloured PprColour.colBold
        $ Out.blankLine
            Out.$+$
              ((Out.text "GhcTagsPlugin: ")
                Out.<> (Out.coloured PprColour.colRedFg (Out.text $ show errorType ++ ":")))
            Out.$$
              (Out.nest 4 $ Out.ppr ms_mod)
            Out.$$
              (Out.nest 8 $ Out.coloured PprColour.colRedFg (Out.text errorMessage))
            Out.$+$
              Out.blankLine
            Out.$+$
              (Out.text "Please report this bug to https://github.com/coot/ghc-tags-plugin/issues")
            Out.$+$
              Out.blankLine

    putDocLn :: Out.SDoc -> IO ()
    putDocLn sdoc =
        putStrLn $
          Out.renderWithStyle
            dynFlags
            sdoc
            (Out.setStyleColoured True $ Out.defaultErrStyle dynFlags)
