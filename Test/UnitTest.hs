{-# LANGUAGE ExistentialQuantification, ImplicitParams #-} 
module Test.UnitTest 
    ( TestCase(..), run_test_cases, test_cases 
    , tempFile, takeLeaves, leafCount
    , selectLeaf, dropLeaves, leaves
    , makeTestSuite, makeTestSuiteOnly
    , testName, TestName
    , callStackLineInfo
    , M, UnitTest(..) 
    , IsTestCase(..)
    , logNothing, PrintLog
    , allLeaves )
where

    -- Libraries
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.SSem
import Control.Exception
import Control.Lens hiding ((<.>))
import Control.Monad
import Control.Monad.Loops
import Control.Monad.Reader
import Control.Monad.RWS
import Control.Precondition

import           Data.Either
import           Data.IORef
import           Data.List
import           Data.List.NonEmpty as NE (sort)
import           Data.String.Indentation
import           Data.String.Lines hiding (lines,unlines)
import           Data.Tuple
import           Data.Typeable

import GHC.Stack
import GHC.SrcLoc

import Language.Haskell.TH

import Prelude
import PseudoMacros


import System.FilePath
import System.IO
import System.IO.Unsafe

import Text.Printf.TH

data TestCase = 
      forall a . (Show a, Eq a, Typeable a) => Case String (IO a) a
    | forall a . (Show a, Eq a, Typeable a) => CalcCase String (IO a) (IO a) 
    | StringCase String (IO String) String
    | LineSetCase String (IO String) String
    | Suite CallStack String [TestCase]
    | WithLineInfo CallStack TestCase
    | forall test. IsTestCase test => Other test

class IsTestCase c where
    makeCase :: Maybe CallStack -> c -> IO UnitTest
    nameOf :: Lens' c String

instance IsTestCase TestCase where
    makeCase _ (WithLineInfo cs t) = makeCase (Just cs) t
    makeCase _ (Suite cs n xs) = Node cs n <$> mapM (makeCase $ Just cs) xs
    makeCase cs (Case x y z) = return UT
                        { name = x
                        , routine = (,logNothing) <$> y
                        , outcome = z
                        , _mcallStack = cs
                        , _display = disp
                        }
    makeCase cs (CalcCase x y z) = do 
            r <- z
            return UT
                { name = x
                , routine  = (,logNothing) <$> y
                , outcome  = r
                , _mcallStack = cs
                , _display = disp
                }
    makeCase cs (StringCase x y z) = return UT 
                            { name = x
                            , routine = (,logNothing) <$> y
                            , outcome = z
                            , _mcallStack = cs
                            , _display = id
                            }
    makeCase cs (LineSetCase x y z) = makeCase cs $ StringCase x 
                                ((asLines %~ NE.sort) <$> y) 
                                (z & asLines %~ NE.sort)
    makeCase cs (Other c) = makeCase cs c
    nameOf f (WithLineInfo x0 c) = WithLineInfo x0 <$> nameOf f c
    nameOf f (Suite x0 n x1) = (\n' -> Suite x0 n' x1) <$> f n
    nameOf f (Case n x0 x1) = (\n' -> Case n' x0 x1) <$> f n
    nameOf f (Other c) = Other <$> nameOf f c
    nameOf f (CalcCase n x0 x1) = (\n' -> CalcCase n' x0 x1) <$> f n
    nameOf f (StringCase n x0 x1) = (\n' -> StringCase n' x0 x1) <$> f n
    nameOf f (LineSetCase n x0 x1) = (\n' -> LineSetCase n' x0 x1) <$> f n

newtype M a = M { runM :: RWST Int [Either (MVar [String]) String] Int (ReaderT (IORef [ThreadId]) IO) a }
    deriving ( Monad,Functor,Applicative,MonadIO
             , MonadReader Int
             , MonadState Int
             , MonadWriter [Either (MVar [String]) String])

instance Indentation Int M where
    -- func = 
    margin_string = do
        n <- margin
        return $ concat $ replicate n "|  "
    _margin _ = id
            
log_failures :: MVar Bool
log_failures = unsafePerformIO $ newMVar True

failure_number :: MVar Int
failure_number = unsafePerformIO $ newMVar 0

take_failure_number :: M ()
take_failure_number = do
    n <- liftIO $ takeMVar failure_number
    liftIO $ putMVar failure_number $ n+1
    put n

callStackLineInfo :: CallStack -> [String]
callStackLineInfo cs = reverse $ map f $ filter (($__FILE__ /=) . srcLocFile) $ map snd $ getCallStack cs
    where
        f c = [printf|%s:%d:%d|] (srcLocFile c) (srcLocStartLine c) (srcLocStartCol c)


new_failure :: CallStack -> String -> String -> String -> M ()
new_failure cs name actual expected = do
    b <- liftIO $ readMVar log_failures
    if b then do
        n <- get
        liftIO $ withFile ([printf|actual-%d.txt|] n) WriteMode $ \h -> do
            hPutStrLn h $ "; " ++ name
            forM_ (callStackLineInfo cs) $ hPutStrLn h . ("; " ++)
            hPutStrLn h actual
        liftIO $ withFile ([printf|expected-%d.txt|] n) WriteMode $ \h -> do
            hPutStrLn h $ "; " ++ name
            forM_ (callStackLineInfo cs) $ hPutStrLn h . ("; " ++)
            hPutStrLn h expected
    else return ()

test_cases :: Pre => String -> [TestCase] -> TestCase
test_cases = Suite ?loc

logNothing :: PrintLog
logNothing = const $ const $ const $ const $ return ()

type PrintLog = CallStack -> String -> String -> String -> M ()

data UnitTest = forall a. Eq a => UT 
    { name :: String
    , routine :: IO (a, PrintLog)
    , outcome :: a
    , _mcallStack :: Maybe CallStack
    , _display :: a -> String
    -- , _source :: FilePath
    }
    | Node { _callStack :: CallStack, name :: String, _children :: [UnitTest] }

-- strip_line_info :: String -> String
-- strip_line_info xs = unlines $ map f $ lines xs
--     where
--         f xs = takeWhile (/= '(') xs

run_test_cases :: (Pre,IsTestCase testCase) 
               => testCase -> IO Bool
run_test_cases xs = do
        swapMVar failure_number 0
        c        <- makeCase Nothing xs 
        ref      <- newIORef []
        (b,_,w)  <- runReaderT (runRWST (runM $ test_suite_string ?loc c) 0 (assertFalse' "??")) ref
        forM_ w $ \ln -> do
            case ln of
                Right xs -> putStrLn xs
                Left xs -> takeMVar xs >>= mapM_ putStrLn
        x <- fmap (uncurry (==)) <$> takeMVar b
        either throw return x
    where        

disp :: (Typeable a, Show a) => a -> String
disp x = fromMaybe (reindent $ show x) (cast x)

test_suite_string :: CallStack
                  -> UnitTest 
                  -> M (MVar (Either SomeException (Int,Int)))
test_suite_string cs' ut = do
        let putLn xs = do
                ys <- mk_lines xs
                -- lift $ putStr $ unlines ys
                tell $ map Right ys
        case ut of
          (UT x y z mli disp) -> forkTest $ do
            let cs = fromMaybe cs' mli
            putLn ("+- " ++ x)
            r <- liftIO $ catch 
                (Right `liftM` y) 
                (\e -> return $ Left $ show (e :: SomeException))
            case r of
                Right (r,printLog) -> 
                    if (r == z)
                    then return (1,1)
                    else do
                        take_failure_number
                        printLog cs x (disp r) (disp z)
                        new_failure cs x (disp r) (disp z)
                        putLn "*** FAILED ***"
                        forM_ (callStackLineInfo cs) $ tell . (:[]) . Right
                        return (0,1) 
                Left m -> do
                    putLn ("   Exception:  " ++ m)
                    return (0,1)
          Node cs n xs -> do
            putLn ("+- " ++ n)
            xs <- indent 1 $ mapM (test_suite_string cs) xs
            forkTest $ do
                xs' <- mergeAll xs
                let xs = map (either (const (0,1)) id) xs' :: [(Int,Int)]
                    x = sum $ map snd xs
                    y = sum $ map fst xs
                putLn ([printf|+- [ Success: %d / %d ]|] y x)
                return (y,x)


leaves :: TestCase -> [String]
leaves (Suite _ _ xs) = concatMap leaves xs
leaves t = [t^.nameOf]


allLeaves :: TestCase -> [TestCase]
allLeaves = allLeaves' ""
    where
        allLeaves' n (Suite _ n' xs) = concatMap (allLeaves' (n ++ n' ++ "/")) xs
        allLeaves' n t = [t & nameOf %~ (n ++)]

selectLeaf :: Int -> TestCase -> TestCase 
selectLeaf n = takeLeaves (n+1) . dropLeaves n

dropLeaves :: Int -> TestCase -> TestCase
dropLeaves n (Suite cs name xs) = Suite cs name (drop (length ws) xs)
    where
        ys = map leafCount xs
        zs = map sum $ inits ys
        ws = dropWhile (<= n) zs
dropLeaves _ x = x

takeLeaves :: Int -> TestCase -> TestCase
takeLeaves n (Suite cs name xs) = Suite cs name (take (length ws) xs)
    where
        ys = map leafCount xs
        zs = map sum $ inits ys
        ws = takeWhile (<= n) zs
takeLeaves _ x = x

leafCount :: TestCase -> Int
leafCount (Suite _ _ xs) = sum $ map leafCount xs
leafCount _ = 1

capabilities :: SSem
capabilities = unsafePerformIO $ new 16

forkTest :: M a -> M (MVar (Either SomeException a))
forkTest cmd = do
    result <- liftIO $ newEmptyMVar
    output <- liftIO $ newEmptyMVar
    r <- ask
    liftIO $ wait capabilities
    --tid <- liftIO myThreadId
    ref <- M $ lift ask
    t <- liftIO $ do
        ref <- newIORef []
        let handler e = do
                ts <- readIORef ref
                mapM_ (`throwTo` e) ts
                putStrLn "failed"
                print e
                putMVar result $ Left e
                putMVar output $ [show e]
        forkIO $ do
            finally (handle handler $ do
                (x,_,w) <- runReaderT (runRWST (runM cmd) r (-1)) ref
                putMVar result (Right x)
                xs <- forM w $ \ln -> do
                    either 
                        takeMVar 
                        (return . (:[])) 
                        ln
                putMVar output $ concat xs)
                (signal capabilities)
    liftIO $ modifyIORef ref (t:)
    tell [Left output]
    return result

mergeAll :: [MVar a] -> M [a]
mergeAll xs = liftIO $ do
    forM xs takeMVar

tempFile_num :: MVar Int
tempFile_num = unsafePerformIO $ newMVar 0

tempFile :: FilePath -> IO FilePath
tempFile path = do
    n <- takeMVar tempFile_num
    putMVar tempFile_num (n+1)
    -- path <- canonicalizePath path
    let path' = dropExtension path ++ "-" ++ show n <.> takeExtension path
    --     finalize = do
    --         b <- doesFileExist path'
    --         when b $
    --             removeFile path'
    -- mkWeakPtr path' (Just finalize)
    return path'

data TestName = TestName String CallStack

testName :: Pre => String -> TestName
testName str = TestName str ?loc

fooNameOf :: TestName -> String
fooNameOf (TestName str _)   = str

fooCallStack :: TestName -> CallStack
fooCallStack (TestName _ cs) = cs

makeTestSuiteOnly :: String -> [Int] -> ExpQ
makeTestSuiteOnly title ts = do
        let namei :: Int -> ExpQ
            namei i = [e| fooNameOf $(varE $ mkName $ "name" ++ show i) |]
            casei i = varE $ mkName $ "case" ++ show i
            loci i = [e| fooCallStack $(varE $ mkName $ "name" ++ show i) |]
            resulti i = varE $ mkName $ "result" ++ show (i :: Int)
            cases = [ [e| WithLineInfo $(loci i) (Case $(namei i) $(casei i) $(resulti i)) |] | i <- ts ]
            titleE = litE $ stringL title
        [e| test_cases $titleE $(listE cases) |]

makeTestSuite :: String -> ExpQ
makeTestSuite title = do
    let names n' = [ "name" ++ n' 
                   , "case" ++ n' 
                   , "result" ++ n' ]
        f n = do
            let n' = show n
            any isJust <$> mapM lookupValueName (names n')
        g n = do
            let n' = show n
            es <- filterM (fmap isNothing . lookupValueName) (names n')
            if null es then return $ Right n
                       else return $ Left es
    xs <- concat <$> sequence
        [ takeWhileM f [0..0]
        , takeWhileM f [1..] ]
    (es,ts) <- partitionEithers <$> mapM g xs
    if null es then do
        makeTestSuiteOnly title ts
    else do
        mapM_ (reportError.[printf|missing test component: '%s'|]) (concat es)
        [e| undefined |]
