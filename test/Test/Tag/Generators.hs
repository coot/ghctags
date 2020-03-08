{-# LANGUAGE OverloadedStrings #-}

module Test.Tag.Generators where

import qualified Data.Char as Char
import           Data.Maybe (isNothing)
import           Data.Text   (Text)
import qualified Data.Text as Text

import           Test.QuickCheck
import           Test.QuickCheck.Instances.Text ()

import           Plugin.GhcTags.Tag

--
-- Generators
--

-- a quick hack
genTextNonEmpty :: Gen Text
genTextNonEmpty =
    suchThat
      (fixText <$> arbitrary)
      (not . Text.null)

-- filter only printable characters, removing tabs and newlines which have
-- special role in vim tag syntax
fixText :: Text -> Text
fixText = Text.filter (\x -> x /= '\t' && x /= '\n' && Char.isPrint x)


genField :: Gen TagField
genField =
        TagField
    <$> suchThat g (not . Text.null)
    <*> g
  where
    g :: Gen Text
    g = fixFieldText <$> arbitrary

-- filter only printable characters, removing tabs, newlines and colons which
-- have special role in vim field syntax
fixFieldText :: Text -> Text
fixFieldText = Text.filter (\x -> x /= '\t' && x /= ':' && x /= '\n' && Char.isPrint x)


-- address cannot contain ";\"" sequence
fixAddr :: Text -> Text
fixAddr = fixText . Text.replace ";\"" ""

wrap :: Char -> Text -> Text
wrap c = Text.cons c . flip Text.snoc c

genGhcKind :: Gen GhcKind
genGhcKind = elements
  [ TkTerm
  , TkFunction
  , TkTypeConstructor
  , TkDataConstructor
  , TkGADTConstructor
  , TkRecordField
  , TkTypeSynonym
  , TkTypeSignature
  , TkPatternSynonym
  , TkTypeClass
  , TkTypeClassMember
  , TkTypeClassInstance
  , TkTypeFamily
  , TkTypeFamilyInstance
  , TkDataTypeFamily
  , TkDataTypeFamilyInstance
  , TkForeignImport
  , TkForeignExport
  ]

genTagKind :: Gen TagKind
genTagKind = oneof
    [ pure NoKind
    , CharKind <$> genChar
    , GhcKind <$> genGhcKind
    ]
  where
    genChar = suchThat arbitrary
                       (\x ->    x /= '\t'
                              && x /= '\n'
                              && x /= ':'
                              && x /= '\NUL'
                              && isNothing (charToGhcKind x)
                       )

--
--
--