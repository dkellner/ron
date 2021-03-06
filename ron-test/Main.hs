{-# OPTIONS -Wno-missing-signatures #-}

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import           Data.ByteString.Lazy (fromStrict)
import qualified Data.ByteString.Lazy.Char8 as BSLC
import           Data.Maybe (fromJust)
import           Hedgehog (Gen, MonadTest, Property, PropertyT, annotate,
                           annotateShow, evalExceptT, forAll, property,
                           tripping, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import           System.Directory (getCurrentDirectory)
import           System.Environment (getEnv, lookupEnv, setEnv)
import           System.Info (os)
import           Test.Tasty.Hedgehog (testProperty)
import           Test.Tasty.TH (defaultMainGenerator)
import qualified Text.Show

import qualified RON.Base64 as Base64
import qualified RON.Binary.Parse as RB
import qualified RON.Binary.Serialize as RB
import           RON.Data (newObject)
import           RON.Data.ORSet (ORSet (ORSet), ObjectORSet (ObjectORSet))
import qualified RON.Data.ORSet as ORSet
import           RON.Data.RGA (RgaString)
import qualified RON.Data.RGA as RGA
import           RON.Event (CalendarEvent (CalendarEvent), Naming (TrieForked),
                            ReplicaId (ReplicaId), applicationSpecific,
                            decodeEvent, encodeEvent, fromCalendarEvent,
                            mkCalendarDateTime)
import           RON.Event.Simulation (runNetworkSimT, runReplicaSimT)
import qualified RON.Text as RT
import qualified RON.Text.Parse as RT
import qualified RON.Text.Serialize as RT
import qualified RON.Text.Serialize.UUID as RT
import           RON.Types (Atom (AInteger, AUuid), Op (Op), RawOp (RawOp),
                            UUID (UUID), WireChunk (Raw), objectFrame, op,
                            opEvent, opObject, opPayload, opRef, opType)
import           RON.Util (ByteStringL)
import qualified RON.UUID as UUID

import qualified Gen
import           HexDump (hexdump)
import qualified LwwStruct
import           Orphans ()
import           Types (TestRecursiveORSet (TestRecursiveORSet), testRecSet,
                        testRecSet_zoom)

main :: IO ()
main = do
    prepareEnv
    $defaultMainGenerator

prepareEnv :: IO ()
prepareEnv = do
    curDir <- getCurrentDirectory
    let buildDir = curDir ++ "/../../.build"

    do  path <- getEnv "PATH"
        setEnv "PATH" $ buildDir ++ ":" ++ path

    do  mLibraryPath <- lookupEnv libraryPathVar
        let libraryPath = case mLibraryPath of
                Nothing -> buildDir
                Just lp -> buildDir ++ ":" ++ lp
        setEnv libraryPathVar libraryPath

  where
    libraryPathVar = case os of
        "darwin" -> "DYLD_LIBRARY_PATH"
        "linux"  -> "LD_LIBRARY_PATH"
        _ -> error $ os ++ " is not supported"

binaryRoundtrip
    :: (Eq a, Show a)
    => Gen a
    -> (a -> Either String ByteStringL)
    -> (ByteStringL -> Either String a)
    -> Property
binaryRoundtrip gen serialize parse = property $ do
    x <- forAll gen
    bytes <- evalEitherS $ serialize x
    annotate $ hexdump bytes
    x' <- evalEitherS $ parse bytes
    x === x'

prop_binary_roundtrip_string =
    binaryRoundtrip
        (Gen.text (Range.exponential 0 1000) Gen.unicode)
        (Right . RB.serializeString)
        RB.parseString

prop_binary_roundtrip_atom =
    -- TODO(2018-11-08, cblp, #4) increase limits
    binaryRoundtrip (Gen.atom 1000) RB.serializeAtom RB.parseAtom

-- TODO(2018-10-02, cblp, #23) fix and enable
-- prop_binary_roundtrip_frame =
--     -- TODO(2018-11-08, cblp, #4) increase limits
--     binaryRoundtrip (Gen.wireFrame 10) RB.serialize RB.parse

textRoundtrip
    :: (Show a, Show b, Applicative f, Eq (f a), Show (f a), Monad m)
    => Gen a -> (a -> b) -> (b -> f a) -> PropertyT m ()
textRoundtrip gen serialize parse = do
    x <- forAll gen
    tripping x serialize parse

prop_text_roundtrip_uuid =
    property $ textRoundtrip Gen.uuid RT.serializeUuid RT.parseUuid

prop_text_roundtrip_uuid_zip = property $ do
    prevKey <- forAll Gen.uuid
    prev    <- forAll Gen.uuid
    textRoundtrip
        Gen.uuid
        (RT.serializeUuidKey prevKey prev)
        (RT.parseUuidKey prevKey prev)
    textRoundtrip Gen.uuid (RT.serializeUuidAtom prev) (RT.parseUuidAtom prev)

prop_text_roundtrip_string = property $
    textRoundtrip
        (Gen.text (Range.exponential 0 10000) Gen.unicode)
        RT.serializeString
        RT.parseString

prop_text_roundtrip_atom =
    property $ textRoundtrip (Gen.atom 10000) RT.serializeAtom RT.parseAtom

prop_text_roundtrip_op =
    -- TODO(2018-11-08, cblp, #4) increase limits
    property $ textRoundtrip (Gen.rawOp 100) RT.serializeRawOp RT.parseOp

prop_text_roundtrip_wireFrame = property $
    -- TODO(2018-11-08, cblp, #4) increase limits
    textRoundtrip (Gen.wireFrame 10) RT.serializeWireFrame RT.parseWireFrame

prop_text_roundtrip_stateFrame = property $
    -- TODO(2018-11-08, cblp, #4) increase limits
    textRoundtrip (Gen.stateFrame 10) RT.serializeStateFrame RT.parseStateFrame

prop_text_roundtrip_frames = property $
    -- TODO(2018-11-08, cblp, #4) increase limits
    textRoundtrip (Gen.wireFrames 10) RT.serializeWireFrames RT.parseWireFrames

prop_filename_roundtrip = property $ do
    ShowAs caseTransform _ <- forAll $ Gen.element
        [ identity    `ShowAs` "identity"
        , map toUpper `ShowAs` "map toUpper"
        , map toLower `ShowAs` "map toLower"
        ]
    textRoundtrip
        Gen.uuid
        (BSLC.pack . caseTransform . UUID.encodeBase32)
        (maybe (Left ("Filename decoding error" :: String)) Right .
            UUID.decodeBase32 . BSLC.unpack)

prop_word64base32_roundtrip = property $
    textRoundtrip
        Gen.word64'
        (fromStrict . Base64.encode64base32short)
        (maybe (Left ("Decoding error" :: String)) Right .
            Base64.decode64base32 . BSLC.toStrict)

prop_base64_roundtrip = property $ do
    bytes <- forAll $ fromStrict <$> Gen.bytes (Range.exponential 0 1000)
    tripping bytes Base64.encode Base64.decode

prop_word60base64_roundtrip = property $ do
    w <- forAll Gen.word60
    tripping w Base64.encode60 Base64.decode60

prop_long_uuid = property $
    Right (UUID 0xa001083105187209 0x89669e8a6aaecb6e) ===
    RT.parseUuid "A0123456789 8abcdefghij"

prop_uuid_abbreviations = property $ do
    -- serialize
    "A/LED" === RT.serializeUuid aLed
    -- parse
    for_ encodings $ \e -> do
        annotateShow e
        Right aLed === RT.parseUuid (BSLC.pack e)
  where
    encodings =
        [ "ALED0000000 00000000000"
        , "ALED000000000000000000"
        , "ALED0000000 0000000000"
        , "ALED0000000$0000000000"
        , "ALED0000000"
        , "A/LED000 0"
        , "A/LED$0"
        , "A/LED"
        ]
    aLed = either error identity $ RT.parseUuid "A/LED"

evalEitherS :: (MonadTest m, HasCallStack) => Either String a -> m a
evalEitherS = evalExceptT . liftEither

prop_event_roundtrip = property $ do
    event <- forAll Gen.event
    tripping event encodeEvent (Just . decodeEvent)

prop_name_roundtip = property $ do
    name <- forAll genName
    tripping name UUID.mkName $ \mu -> do
        u <- mu
        (n, "") <- UUID.getName u
        pure $ dropZeroesEnd n
    scope <- forAll genName
    tripping (scope, name) (uncurry UUID.mkScopedName) $ \mu -> do
        u <- mu
        (s, n) <- UUID.getName u
        pure (dropZeroesEnd s, dropZeroesEnd n)
  where
    genName
        = fmap (dropZeroesEnd . BS.pack) $ Gen.list (Range.linear 1 10)
        $ Gen.element $ BS.unpack Base64.alphabet
    dropZeroesEnd = fst . BSC.spanEnd (== '0')

prop_ron_json_example = let
    input =
        "*lww #1TUAQ+gritzko @`   :bar = 1  ;\n\
        \     #(R            @`   :foo > (Q ;"
    output =
        [ Raw RawOp
            { opType = lwwType
            , opObject = bar
            , op = Op{opEvent = bar, opRef = barName, opPayload = [AInteger 1]}
            }
        , Raw RawOp
            { opType = lwwType
            , opObject = foo
            , op = Op{opEvent = foo, opRef = fooName, opPayload = [AUuid bar]}
            }
        ]
    barName = $(UUID.liftName "bar")
    bar     = encodeEvent $ fromCalendarEvent $ CalendarEvent
                (fromJust $ mkCalendarDateTime (2017, 10, 31) (10, 26, 00))
                replicaGritzko
    fooName = $(UUID.liftName "foo")
    foo     = encodeEvent $ fromCalendarEvent $ CalendarEvent
                (fromJust $ mkCalendarDateTime (2017, 10, 31) (10, 27, 00))
                replicaGritzko
    gritzko = fromJust $ Base64.decode60 "gritzko"
    replicaGritzko = ReplicaId TrieForked gritzko
    in
    property $ do
        parsed <- evalEitherS $ RT.parseWireFrame input
        output === parsed

lwwType = $(UUID.liftName "lww")

prop_lwwStruct = LwwStruct.prop_lwwStruct

prop_RGA_edit_idempotency = property $ do
    textX <- forAll Gen.shortText
    textY <- forAll Gen.shortText
    evalExceptT $
        runNetworkSimT $ runReplicaSimT (applicationSpecific 271) $ do
            rgaX <-                       RGA.newFromText textX
            rgaY <- (`execStateT` rgaX) $ RGA.editText    textY
            Right textY === RGA.getText rgaY

prop_RGA_edit_idempotency_back = property $ do
    textX <- forAll Gen.shortText
    textY <- forAll Gen.shortText
    evalExceptT $
        runNetworkSimT $ runReplicaSimT (applicationSpecific 271) $ do
            rgaX  <-                       RGA.newFromText textX
            rgaY  <- (`execStateT` rgaX) $ RGA.editText    textY
            rgaX' <- (`execStateT` rgaY) $ RGA.editText    textX
            Right textX === RGA.getText rgaX'

prop_RGA_delete_deleted = let
    prep = map BSLC.words . BSLC.lines . RT.serializeStateFrame . objectFrame
    rga0expect =
        [ ["*rga", "#B/000015NGPU+000000003f", "@`(0kmiUz", "!"]
        , ["@)v", "'h'"]
        , ["@)w", "'e'"]
        , ["@)x", "'l'"]
        , ["@)y", "'l'"]
        , ["@)z", "'o'"]
        , ["."]
        ]
    rga1expect =
        [ ["*rga", "#B/000015NGPU+000000003f", "@`(4Q8IxU", "!"]
        , ["@(0kmiUv",          "'h'"]
        , ["@)w",               "'e'"]
        , ["@)x",               "'l'"]
        , ["@)y",               "'l'"]
        , ["@)z", ":`(4Q8IxU",  "'o'"]
        , ["."]
        ]
    rga2expect =
        [ ["*rga", "#B/000015NGPU+000000003f", "@`(AVmKxU", "!"]
        , ["@(0kmiUv",                  "'h'"]
        , ["@)w",                       "'e'"]
        , ["@)x",                       "'l'"]
        , ["@)y",       ":`(75FOxU",    "'l'"]
        , ["@)z",       ":(4Q8IxU",     "'o'"]
        , ["@(AVmKxU",  ":0",           "'p'"]
        , ["."]
        ]
    in
    property $ evalExceptT $
    runNetworkSimT $ runReplicaSimT (applicationSpecific 234) $ do
        rga0 <- RGA.newFromText "hello"
        rga0expect === prep rga0
        (`evalStateT` rga0) $ do
            RGA.editText "hell"
            rga1 <- get
            rga1expect === prep rga1
            RGA.editText "help"
            rga2 <- get
            rga2expect === prep rga2

prop_base64_isLetter = property $ do
    c <- forAll $ Gen.word8 Range.constantBounded
    (c `BS.elem` Base64.alphabet) === Base64.isLetter c

data ShowAs a = ShowAs a String

instance Show (ShowAs a) where
    show (ShowAs _ s) = s

prop_ORSet = let
    prep = map BSLC.words . BSLC.lines . RT.serializeStateFrame . objectFrame
    set0expect = [["*set", "#B/00000omion+000000005j", "@`", "!"], ["."]]
    set1expect =
        [ ["*set", "#B/00000omion+000000005j", "@`(2xPmJ2", "!"]
        , ["@", "=370"]
        , ["."]
        ]
    set2expect =
        [ ["*set", "#B/00000omion+000000005j", "@`(3Jlz_Y", "!"]
        , [":`(2xPmJ2"]
        , ["."]
        ]
    in
    property $ evalExceptT $
    runNetworkSimT $ runReplicaSimT (applicationSpecific 366) $ do
        set0 <- newObject $ ORSet @Int64 []
        set0expect === prep set0
        (`evalStateT` set0) $ do
            ORSet.addValue 370
            set1 <- get
            set1expect === prep set1
            ORSet.removeValue 370
            set2 <- get
            set2expect === prep set2

prop_ObjectORSet = let
    prep = map BSLC.words . BSLC.lines . RT.serializeStateFrame . objectFrame
    set0expect = [["*set", "#B/00000omilG+000000006G", "@`", "!"], ["."]]
    set1expect =
        [ ["*rga", "#B/00005~K_SG+000000006G", "@`(2lqPwO", "!"]
            , ["@)M", "'4'"]
            , ["@)N", "'0'"]
            , ["@)O", "'3'"]
        , ["*set", "#(0omilG", "@(6Io4NG", "!"]
            , ["@", ">(5~K_SG"]
        , ["."]
        ]
    set2expect =
        [ ["*rga", "#B/00005~K_SG+000000006G", "@`(2lqPwO", "!"]
            , ["@)M", "'4'"]
            , ["@)N", "'0'"]
            , ["@)O", "'3'"]
        , ["*set", "#(0omilG", "@(8QQEHG", "!"]
            , [":`(6Io4NG"]
        , ["."]
        ]
    in
    property $ evalExceptT $
    runNetworkSimT $ runReplicaSimT (applicationSpecific 400) $ do
        set0 <- newObject $ ObjectORSet @RgaString []
        set0expect === prep set0
        rga0 <- RGA.newFromText "403"
        (`evalStateT` set0) $ do
            ORSet.addRef rga0
            set1 <- get
            set1expect === prep set1
            ORSet.removeRef rga0
            set2 <- get
            set2expect === prep set2

prop_ObjectORSet_recursive = let
    prep = map BSLC.words . BSLC.lines . RT.serializeStateFrame . objectFrame
    set0 = TestRecursiveORSet{testRecSet = []}
    set1expect =
        [ ["*lww", "#B/00004bfsbH+000000006P", "@`", "!"]
            , [":testRecSet", ">(0omil7"]
        , ["*set", "#(0omil7", "@`", ":0", "!"]
        , ["."]
        ]
    set2expect =
        [ ["*lww", "#B/00004bfsbH+000000006P", "@`", "!"]
            , [":testRecSet", ">(0omil7"]
        , ["*set", "#(0omil7", "@(6yT_gy", ":0", "!"]
            , ["@", ">(4bfsbH"]
        , ["."]
        ]
    in
    property $ evalExceptT $
    runNetworkSimT $ runReplicaSimT (applicationSpecific 409) $ do
        set1 <- newObject set0
        set1expect === prep set1
        (`evalStateT` set1) $ do
            testRecSet_zoom $ ORSet.addRef set1
            set2 <- get
            set2expect === prep set2
