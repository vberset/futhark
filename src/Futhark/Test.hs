{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
-- | Facilities for reading Futhark test programs.  A Futhark test
-- program is an ordinary Futhark program where an initial comment
-- block specifies input- and output-sets.
module Futhark.Test
       ( testSpecFromFile
       , testSpecFromFileOrDie
       , testSpecsFromPaths
       , testSpecsFromPathsOrDie
       , valuesFromByteString
       , getValues
       , getValuesBS
       , compareValues
       , compareValues1
       , testRunReferenceOutput
       , getExpectedResult
       , compileProgram
       , runProgram
       , ensureReferenceOutput
       , determineTuning
       , binaryName
       , Mismatch

       , ProgramTest (..)
       , StructureTest (..)
       , StructurePipeline (..)
       , WarningTest (..)
       , TestAction (..)
       , ExpectedError (..)
       , InputOutputs (..)
       , TestRun (..)
       , ExpectedResult (..)
       , Success(..)
       , Values (..)
       , GenValue (..)
       , Value
       )
       where

import Control.Applicative
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString as SBS
import Control.Exception (catch)
import Control.Monad
import Control.Monad.Except
import qualified Data.Map.Strict as M
import Data.Char
import Data.Functor
import Data.Maybe
import Data.List
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import Data.Void
import System.FilePath
import Codec.Compression.GZip
import Codec.Compression.Zlib.Internal (DecompressError)
import qualified Control.Exception.Base as E

import Text.Megaparsec hiding (many, some)
import Text.Megaparsec.Char
import Text.Regex.TDFA
import System.Directory
import System.Exit
import System.Process.ByteString (readProcessWithExitCode)
import System.IO (withFile, IOMode(..), hFileSize, hClose)
import System.IO.Error
import System.IO.Temp

import Prelude

import Futhark.Analysis.Metrics
import Futhark.Representation.Primitive
       (IntType(..), intValue, FloatType(..), intByteSize, floatByteSize)
import Futhark.Test.Values
import Futhark.Util (directoryContents, pmapIO)
import Futhark.Util.Pretty (pretty, prettyText)
import Language.Futhark.Syntax (PrimType(..), PrimValue(..))
import Language.Futhark.Attributes (primValueType, primByteSize)

-- | Description of a test to be carried out on a Futhark program.
-- The Futhark program is stored separately.
data ProgramTest =
  ProgramTest { testDescription ::
                   T.Text
              , testTags ::
                   [T.Text]
              , testAction ::
                   TestAction
              }
  deriving (Show)

-- | How to test a program.
data TestAction
  = CompileTimeFailure ExpectedError
  | RunCases [InputOutputs] [StructureTest] [WarningTest]
  deriving (Show)

-- | Input and output pairs for some entry point(s).
data InputOutputs = InputOutputs { iosEntryPoint :: T.Text
                                 , iosTestRuns :: [TestRun] }
  deriving (Show)

-- | The error expected for a negative test.
data ExpectedError = AnyError
                   | ThisError T.Text Regex

instance Show ExpectedError where
  show AnyError = "AnyError"
  show (ThisError r _) = "ThisError " ++ show r

-- | How a program can be transformed.
data StructurePipeline = KernelsPipeline
                       | SOACSPipeline
                       | SequentialCpuPipeline
                       | GpuPipeline
                       deriving (Show)

-- | A structure test specifies a compilation pipeline, as well as
-- metrics for the program coming out the other end.
data StructureTest = StructureTest StructurePipeline AstMetrics
                     deriving (Show)

-- | A warning test requires that a warning matching the regular
-- expression is produced.  The program must also compile succesfully.
data WarningTest = ExpectedWarning T.Text Regex

instance Show WarningTest where
  show (ExpectedWarning r _) = "ExpectedWarning " ++ T.unpack r

-- | A condition for execution, input, and expected result.
data TestRun = TestRun
               { runTags :: [String]
               , runInput :: Values
               , runExpectedResult :: ExpectedResult Success
               , runIndex :: Int
               , runDescription :: String
               }
             deriving (Show)

-- | Several Values - either literally, or by reference to a file, or
-- to be generated on demand.
data Values = Values [Value]
            | InFile FilePath
            | GenValues [GenValue]
            deriving (Show)

data GenValue = GenValue [Int] PrimType
                -- ^ Generate a value of the given rank and primitive
                -- type.  Scalars are considered 0-ary arrays.
              | GenPrim PrimValue
                -- ^ A fixed non-randomised primitive value.
              deriving (Show)

-- | A prettyprinted representation of type of value produced by a
-- 'GenValue'.
genValueType :: GenValue -> String
genValueType (GenValue ds t) =
  concatMap (\d -> "[" ++ show d ++ "]") ds ++ pretty t
genValueType (GenPrim v) =
  pretty v

-- | How a test case is expected to terminate.
data ExpectedResult values
  = Succeeds (Maybe values) -- ^ Execution suceeds, with or without
                            -- expected result values.
  | RunTimeFailure ExpectedError -- ^ Execution fails with this error.
  deriving (Show)

-- | The result expected from a succesful execution.
data Success = SuccessValues Values
             -- ^ These values are expected.
             | SuccessGenerateValues
             -- ^ Compute expected values from executing a known-good
             -- reference implementation.
             deriving (Show)

type Parser = Parsec Void T.Text

lexeme :: Parser a -> Parser a
lexeme p = p <* space

-- Like 'lexeme', but does not consume trailing linebreaks.
lexeme' :: Parser a -> Parser a
lexeme' p = p <* many (oneOf (" \t" :: String))

lexstr :: T.Text -> Parser ()
lexstr = void . try . lexeme . string

-- Like 'lexstr', but does not consume trailing linebreaks.
lexstr' :: T.Text -> Parser ()
lexstr' = void . try . lexeme' . string

braces :: Parser a -> Parser a
braces p = lexstr "{" *> p <* lexstr "}"

parseNatural :: Parser Int
parseNatural = lexeme $ foldl' (\acc x -> acc * 10 + x) 0 .
               map num <$> some digitChar
  where num c = ord c - ord '0'

parseDescription :: Parser T.Text
parseDescription = lexeme $ T.pack <$> (anySingle `manyTill` parseDescriptionSeparator)

parseDescriptionSeparator :: Parser ()
parseDescriptionSeparator = try (string descriptionSeparator >>
                                 void (satisfy isSpace `manyTill` newline)) <|> eof

descriptionSeparator :: T.Text
descriptionSeparator = "=="

parseTags :: Parser [T.Text]
parseTags = lexstr "tags" *> braces (many parseTag) <|> pure []
  where parseTag = T.pack <$> lexeme (some $ satisfy tagConstituent)

tagConstituent :: Char -> Bool
tagConstituent c = isAlphaNum c || c == '_' || c == '-'

parseAction :: Parser TestAction
parseAction = CompileTimeFailure <$> (lexstr' "error:" *> parseExpectedError) <|>
              (RunCases <$> parseInputOutputs <*>
               many parseExpectedStructure <*> many parseWarning)

parseInputOutputs :: Parser [InputOutputs]
parseInputOutputs = do
  entrys <- parseEntryPoints
  cases <- parseRunCases
  return $ map (`InputOutputs` cases) entrys

parseEntryPoints :: Parser [T.Text]
parseEntryPoints = (lexstr "entry:" *> many entry <* space) <|> pure ["main"]
  where constituent c = not (isSpace c) && c /= '}'
        entry = lexeme' $ T.pack <$> some (satisfy constituent)

parseRunTags :: Parser [String]
parseRunTags = many parseTag
  where parseTag = try $ lexeme $ do s <- some $ satisfy tagConstituent
                                     guard $ s `notElem` ["input", "structure", "warning"]
                                     return s

parseRunCases :: Parser [TestRun]
parseRunCases = parseRunCases' (0::Int)
  where parseRunCases' i = (:) <$> parseRunCase i <*> parseRunCases' (i+1)
                           <|> pure []
        parseRunCase i = do
          tags <- parseRunTags
          lexstr "input"
          input <- if "random" `elem` tags
                   then parseRandomValues
                   else parseValues
          expr <- parseExpectedResult
          return $ TestRun tags input expr i $ desc i input

        -- If the file is gzipped, we strip the 'gz' extension from
        -- the dataset name.  This makes it more convenient to rename
        -- from 'foo.in' to 'foo.in.gz', as the reported dataset name
        -- does not change (which would make comparisons to historical
        -- data harder).
        desc _ (InFile path)
          | takeExtension path == ".gz" = dropExtension path
          | otherwise                   = path
        desc i (Values vs) =
          -- Turn linebreaks into space.
          "#" ++ show i ++ " (\"" ++ unwords (lines vs') ++ "\")"
          where vs' = case unwords (map pretty vs) of
                        s | length s > 50 -> take 50 s ++ "..."
                          | otherwise     -> s
        desc _ (GenValues gens) =
          unwords $ map genValueType gens

parseExpectedResult :: Parser (ExpectedResult Success)
parseExpectedResult =
  (lexstr "auto" *> lexstr "output" $> Succeeds (Just SuccessGenerateValues)) <|>
  (Succeeds . Just . SuccessValues <$> (lexstr "output" *> parseValues)) <|>
  (RunTimeFailure <$> (lexstr "error:" *> parseExpectedError)) <|>
  pure (Succeeds Nothing)

parseExpectedError :: Parser ExpectedError
parseExpectedError = lexeme $ do
  s <- T.strip <$> restOfLine
  if T.null s
    then return AnyError
         -- blankCompOpt creates a regular expression that treats
         -- newlines like ordinary characters, which is what we want.
    else ThisError s <$> makeRegexOptsM blankCompOpt defaultExecOpt (T.unpack s)

parseRandomValues :: Parser Values
parseRandomValues = GenValues <$> between (lexstr "{") (lexstr "}") (many parseGenValue)

parseGenValue :: Parser GenValue
parseGenValue = choice [ GenValue <$> many dim <*> parsePrimType
                       , lexeme $ GenPrim <$> choice [i8, i16, i32, i64,
                                                      u8, u16, u32, u64,
                                                      int SignedValue Int32 ""]
                       ]
  where digits = some (satisfy isDigit)
        dim = between (lexstr "[") (lexstr "]") $
              lexeme $ read <$> digits

        readint :: String -> Integer
        readint = read -- To avoid warnings.

        int f t s = try $ lexeme $ f . intValue t  . readint <$> digits <*
                    string s <*
                    notFollowedBy (satisfy isAlphaNum)
        i8  = int SignedValue Int8 "i8"
        i16 = int SignedValue Int16 "i16"
        i32 = int SignedValue Int32 "i32"
        i64 = int SignedValue Int64 "i64"
        u8  = int UnsignedValue Int8 "u8"
        u16 = int UnsignedValue Int16 "u16"
        u32 = int UnsignedValue Int32 "u32"
        u64 = int UnsignedValue Int64 "u64"

parsePrimType :: Parser PrimType
parsePrimType =
  choice [ lexstr "i8" $> Signed Int8
         , lexstr "i16" $> Signed Int16
         , lexstr "i32" $> Signed Int32
         , lexstr "i64" $> Signed Int64
         , lexstr "u8" $> Unsigned Int8
         , lexstr "u16" $> Unsigned Int16
         , lexstr "u32" $> Unsigned Int32
         , lexstr "u64" $> Unsigned Int64
         , lexstr "f32" $> FloatType Float32
         , lexstr "f64" $> FloatType Float64
         , lexstr "bool" $> Bool
         ]

parseValues :: Parser Values
parseValues = do s <- parseBlock
                 case valuesFromByteString "input block contents" $ BS.fromStrict $ T.encodeUtf8 s of
                   Left err -> fail err
                   Right vs -> return $ Values vs
              <|> lexstr "@" *> lexeme (InFile . T.unpack <$> nextWord)

parseBlock :: Parser T.Text
parseBlock = lexeme $ braces (T.pack <$> parseBlockBody 0)

parseBlockBody :: Int -> Parser String
parseBlockBody n = do
  c <- lookAhead anySingle
  case (c,n) of
    ('}', 0) -> return mempty
    ('}', _) -> (:) <$> anySingle <*> parseBlockBody (n-1)
    ('{', _) -> (:) <$> anySingle <*> parseBlockBody (n+1)
    _        -> (:) <$> anySingle <*> parseBlockBody n

restOfLine :: Parser T.Text
restOfLine = T.pack <$> (anySingle `manyTill` (void newline <|> eof))

nextWord :: Parser T.Text
nextWord = T.pack <$> (anySingle `manyTill` satisfy isSpace)

parseWarning :: Parser WarningTest
parseWarning = lexstr "warning:" >> parseExpectedWarning
  where parseExpectedWarning = lexeme $ do
          s <- T.strip <$> restOfLine
          ExpectedWarning s <$> makeRegexOptsM blankCompOpt defaultExecOpt (T.unpack s)

parseExpectedStructure :: Parser StructureTest
parseExpectedStructure =
  lexstr "structure" *>
  (StructureTest <$> optimisePipeline <*> parseMetrics)

optimisePipeline :: Parser StructurePipeline
optimisePipeline = lexstr "distributed" $> KernelsPipeline <|>
                   lexstr "gpu" $> GpuPipeline <|>
                   lexstr "cpu" $> SequentialCpuPipeline <|>
                   pure SOACSPipeline

parseMetrics :: Parser AstMetrics
parseMetrics = braces $ fmap (AstMetrics . M.fromList) $ many $
               (,) <$> (T.pack <$> lexeme (some (satisfy constituent))) <*> parseNatural
  where constituent c = isAlpha c || c == '/'

testSpec :: Parser ProgramTest
testSpec =
  ProgramTest <$> parseDescription <*> parseTags <*> parseAction

parserState :: Int -> FilePath -> s -> State s e
parserState line name t =
  State { stateInput = t
        , stateOffset = 0
        , statePosState = PosState
          { pstateInput = t
          , pstateOffset = 0
          , pstateSourcePos = SourcePos
                              { sourceName = name
                              , sourceLine = mkPos line
                              , sourceColumn = mkPos 3 }
          , pstateTabWidth = defaultTabWidth
          , pstateLinePrefix = "-- "}
        , stateParseErrors = []
        }


readTestSpec :: Int -> String -> T.Text -> Either (ParseErrorBundle T.Text Void) ProgramTest
readTestSpec line name t =
  snd $ runParser' (testSpec <* eof) $ parserState line name t

readInputOutputs :: Int -> String -> T.Text -> Either (ParseErrorBundle T.Text Void) [InputOutputs]
readInputOutputs line name t =
  snd $ runParser' (parseDescription *> space *> parseInputOutputs <* eof) $
  parserState line name t

commentPrefix :: T.Text
commentPrefix = T.pack "--"

couldNotRead :: IOError -> IO (Either String a)
couldNotRead = return . Left . show

-- | Read the test specification from the given Futhark program.
testSpecFromFile :: FilePath -> IO (Either String ProgramTest)
testSpecFromFile path = do
  blocks_or_err <-
    (Right . testBlocks <$> T.readFile path)
    `catch` couldNotRead
  case blocks_or_err of
    Left err -> return $ Left err
    Right blocks -> do
      let (first_spec_line, first_spec, rest_specs) =
            case blocks of []       -> (0, mempty, [])
                           (n,s):ss -> (n, s, ss)
      case readTestSpec (1+first_spec_line) path first_spec of
        Left err -> return $ Left $ errorBundlePretty err
        Right v  -> return $ foldM moreCases v rest_specs

  where moreCases test (lineno, cases) =
          case readInputOutputs lineno path cases of
            Left err     -> Left $ errorBundlePretty err
            Right cases' ->
              case testAction test of
                RunCases old_cases structures warnings ->
                  Right test { testAction = RunCases (old_cases ++ cases') structures warnings }
                _ -> Left "Secondary test block provided, but primary test block specifies compilation error."

-- | Like 'testSpecFromFile', but kills the process on error.
testSpecFromFileOrDie :: FilePath -> IO ProgramTest
testSpecFromFileOrDie prog = do
  spec_or_err <- testSpecFromFile prog
  case spec_or_err of
    Left err -> do putStrLn err
                   exitFailure
    Right spec -> return spec

testBlocks :: T.Text -> [(Int, T.Text)]
testBlocks = mapMaybe isTestBlock . commentBlocks
  where isTestBlock (n,block)
          | any ((" " <> descriptionSeparator) `T.isPrefixOf`) block =
              Just (n, T.unlines block)
          | otherwise =
              Nothing

commentBlocks :: T.Text -> [(Int, [T.Text])]
commentBlocks = commentBlocks' . zip [0..] . T.lines
  where isComment = (commentPrefix `T.isPrefixOf`)
        commentBlocks' ls =
          let ls' = dropWhile (not . isComment . snd) ls
          in case ls' of
            [] -> []
            (n,_) : _ ->
              let (block, ls'') = span (isComment . snd) ls'
                  block' = map (T.drop 2 . snd) block
              in (n, block') : commentBlocks' ls''

-- | Read test specifications from the given path, which can be a file
-- or directory containing @.fut@ files and further directories.
testSpecsFromPath :: FilePath -> IO (Either String [(FilePath, ProgramTest)])
testSpecsFromPath path = do
  programs_or_err <- (Right <$> testPrograms path) `catch` couldNotRead
  case programs_or_err of
    Left err -> return $ Left err
    Right programs -> do
      specs_or_errs <- mapM testSpecFromFile programs
      return $ zip programs <$> sequence specs_or_errs

-- | Read test specifications from the given paths, which can be a
-- files or directories containing @.fut@ files and further
-- directories.
testSpecsFromPaths :: [FilePath]
                   -> IO (Either String [(FilePath, ProgramTest)])
testSpecsFromPaths = fmap (fmap concat . sequence) . mapM testSpecsFromPath

-- | Like 'testSpecsFromPaths', but kills the process on errors.
testSpecsFromPathsOrDie :: [FilePath]
                        -> IO [(FilePath, ProgramTest)]
testSpecsFromPathsOrDie dirs = do
  specs_or_err <- testSpecsFromPaths dirs
  case specs_or_err of
    Left err -> do putStrLn err
                   exitFailure
    Right specs -> return specs

testPrograms :: FilePath -> IO [FilePath]
testPrograms dir = filter isFut <$> directoryContents dir
  where isFut = (==".fut") . takeExtension

-- | Try to parse a several values from a byte string.  The 'String'
-- parameter is used for error messages.
valuesFromByteString :: String -> BS.ByteString -> Either String [Value]
valuesFromByteString srcname =
  maybe (Left $ "Cannot parse values from '" ++ srcname ++ "'") Right . readValues

-- | Get the actual core Futhark values corresponding to a 'Values'
-- specification.  The 'FilePath' is the directory which file paths
-- are read relative to.
getValues :: (MonadFail m, MonadIO m) => FilePath -> Values -> m [Value]
getValues _ (Values vs) =
  return vs
getValues dir v = do
  s <- getValuesBS dir v
  case valuesFromByteString file s of
    Left e   -> fail e
    Right vs -> return vs
  where file = case v of Values{} -> "<values>"
                         InFile f -> f
                         GenValues{} -> "<randomly generated>"

-- | Extract a pretty representation of some 'Values'.  In the IO
-- monad because this might involve reading from a file.  There is no
-- guarantee that the resulting byte string yields a readable value.
getValuesBS :: MonadIO m => FilePath -> Values -> m BS.ByteString
getValuesBS _ (Values vs) =
  return $ BS.fromStrict $ T.encodeUtf8 $ T.unlines $ map prettyText vs
getValuesBS dir (InFile file) =
  case takeExtension file of
   ".gz" -> liftIO $ do
     s <- E.try readAndDecompress
     case s of
       Left e   -> fail $ show file ++ ": " ++ show (e :: DecompressError)
       Right s' -> return s'

   _  -> liftIO $ BS.readFile file'
  where file' = dir </> file
        readAndDecompress = do s <- BS.readFile file'
                               E.evaluate $ decompress s
getValuesBS dir (GenValues gens) =
  mconcat <$> mapM (getGenBS dir) gens

-- | There is a risk of race conditions when multiple programs have
-- identical 'GenValues'.  In such cases, multiple threads in 'futhark
-- test' might attempt to create the same file (or read from it, while
-- something else is constructing it).  This leads to a mess.  To
-- avoid this, we create a temporary file, and only when it is
-- complete do we move it into place.  It would be better if we could
-- use file locking, but that does not work on some file systems.  The
-- approach here seems robust enough for now, but certainly it could
-- be made even better.  The race condition that remains should mostly
-- result in duplicate work, not crashes or data corruption.
getGenBS :: MonadIO m => FilePath -> GenValue -> m BS.ByteString
getGenBS dir gen = do
  liftIO $ createDirectoryIfMissing True $ dir </> "data"
  exists_and_proper_size <- liftIO $
    withFile (dir </> file) ReadMode (fmap (== genFileSize gen) . hFileSize)
    `catch` \ex -> if isDoesNotExistError ex then return False
                   else E.throw ex
  unless exists_and_proper_size $ liftIO $ do
    s <- genValues [gen]
    withTempFile (dir </> "data") (genFileName gen) $ \tmpfile h -> do
      hClose h -- We will be writing and reading this ourselves.
      SBS.writeFile tmpfile s
      renameFile tmpfile $ dir </> file
  getValuesBS dir $ InFile file
  where file = "data" </> genFileName gen

genValues :: [GenValue] -> IO SBS.ByteString
genValues gens = do
  (code, stdout, stderr) <- readProcessWithExitCode "futhark" ("dataset":args) mempty
  case code of
    ExitSuccess ->
      return stdout
    ExitFailure e ->
      fail $ "'futhark dataset' failed with exit code " ++ show e ++ " and stderr:\n" ++
      map (chr . fromIntegral) (SBS.unpack stderr)
  where args = "-b" : concatMap argForGen gens
        argForGen g = ["-g", genValueType g]

genFileName :: GenValue -> FilePath
genFileName gen = genValueType gen ++ ".in"

-- | Compute the expected size of the file.  We use this to check
-- whether an existing file is broken/truncated.
genFileSize :: GenValue -> Integer
genFileSize = genSize
  where header_size = 1 + 1 + 1 + 4 -- 'b' <version> <num_dims> <type>

        genSize (GenValue ds t) = header_size + toInteger (length ds) * 8 +
                                  product (map toInteger ds) * primSize t
        genSize (GenPrim v) =
          header_size + primByteSize (primValueType v)

        primSize (Signed it) = intByteSize it
        primSize (Unsigned it) = intByteSize it
        primSize (FloatType ft) = floatByteSize ft
        primSize Bool = 1

-- | When/if generating a reference output file for this run, what
-- should it be called?  Includes the "data/" folder.
testRunReferenceOutput :: FilePath -> T.Text -> TestRun -> FilePath
testRunReferenceOutput prog entry tr =
  "data"
  </> takeBaseName prog
  <> ":" <> T.unpack entry
  <> "-" <> map clean (runDescription tr)
  <.> "out"
  where clean '/' = '_' -- Would this ever happen?
        clean ' ' = '_'
        clean c = c

-- | Get the values corresponding to an expected result, if any.
getExpectedResult :: (MonadFail m, MonadIO m) =>
                     FilePath -> T.Text -> TestRun
                  -> m (ExpectedResult [Value])
getExpectedResult prog entry tr =
  case runExpectedResult tr of
    (Succeeds (Just (SuccessValues vals))) ->
      Succeeds . Just <$> getValues (takeDirectory prog) vals
    Succeeds (Just SuccessGenerateValues) ->
      getExpectedResult prog entry
      tr { runExpectedResult = Succeeds $ Just $ SuccessValues $ InFile $
                               testRunReferenceOutput prog entry tr }
    Succeeds Nothing ->
      return $ Succeeds Nothing
    RunTimeFailure err ->
      return $ RunTimeFailure err


-- | The name we use for compiled programs.
binaryName :: FilePath -> FilePath
binaryName = dropExtension

compileProgram :: (MonadIO m, MonadError [T.Text] m) =>
                  [String] -> FilePath -> String -> FilePath
               -> m (SBS.ByteString, SBS.ByteString)
compileProgram extra_options futhark backend program = do
  (futcode, stdout, stderr) <- liftIO $ readProcessWithExitCode futhark (backend:options) ""
  case futcode of
    ExitFailure 127 -> throwError [progNotFound $ T.pack futhark]
    ExitFailure _   -> throwError [T.decodeUtf8 stderr]
    ExitSuccess     -> return ()
  return (stdout, stderr)
  where binOutputf = binaryName program
        options = [program, "-o", binOutputf] ++ extra_options
        progNotFound s = s <> ": command not found"

runProgram :: MonadIO m =>
              String -> [String]
           -> String -> T.Text -> Values
           -> m (ExitCode, SBS.ByteString, SBS.ByteString)
runProgram runner extra_options prog entry input = do
  let progbin = binaryName prog
      dir = takeDirectory prog
      binpath = "." </> progbin
      entry_options = ["-e", T.unpack entry]

      (to_run, to_run_args)
        | null runner = (binpath, entry_options ++ extra_options)
        | otherwise = (runner, binpath : entry_options ++ extra_options)

  input' <- getValuesBS dir input
  liftIO $ readProcessWithExitCode to_run to_run_args $ BS.toStrict input'

-- | Ensure that any reference output files exist, or create them (by
-- compiling the program with the reference compiler and running it on
-- the input) if necessary.
ensureReferenceOutput :: (MonadIO m, MonadError [T.Text] m) =>
                         Maybe Int -> FilePath -> String -> FilePath -> [InputOutputs]
                      -> m ()
ensureReferenceOutput concurrency futhark compiler prog ios = do
  missing <- filterM isReferenceMissing $ concatMap entryAndRuns ios

  unless (null missing) $ do
    void $ compileProgram [] futhark compiler prog

    res <- liftIO $ flip (pmapIO concurrency) missing $ \(entry, tr) -> do
      (code, stdout, stderr) <- runProgram "" ["-b"] prog entry $ runInput tr
      case code of
        ExitFailure e ->
          return $ Left
          [T.pack $ "Reference dataset generation failed with exit code " ++
           show e ++ " and stderr:\n" ++
           map (chr . fromIntegral) (SBS.unpack stderr)]
        ExitSuccess -> do
          let f = file (entry, tr)
          liftIO $ createDirectoryIfMissing True $ takeDirectory f
          SBS.writeFile f stdout
          return $ Right ()

    case sequence_ res of
      Left err -> throwError err
      Right () -> return ()

  where file (entry, tr) =
          takeDirectory prog </> testRunReferenceOutput prog entry tr

        entryAndRuns (InputOutputs entry rts) = map (entry,) rts

        isReferenceMissing (entry, tr)
          | Succeeds (Just SuccessGenerateValues) <- runExpectedResult tr =
              liftIO . fmap not . doesFileExist . file $ (entry, tr)
          | otherwise =
              return False

-- | Determine the --tuning options to pass to the program.  The first
-- argument is the extension of the tuning file, or 'Nothing' if none
-- should be used.
determineTuning :: MonadIO m => Maybe FilePath -> FilePath -> m ([String], String)
determineTuning Nothing _ = return ([], mempty)
determineTuning (Just ext) program = do
  exists <- liftIO $ doesFileExist (program <.> ext)
  if exists
    then return (["--tuning", program <.> ext],
                 " (using " <> takeFileName (program <.> ext) <> ")")
    else return ([], mempty)
