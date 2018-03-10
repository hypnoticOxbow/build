{-# LANGUAGE Rank2Types, FlexibleContexts, GeneralizedNewtypeDeriving, ScopedTypeVariables, RecordWildCards, ConstraintKinds, TypeFamilies #-}

module Neil.Builder(
    dumb,
    dumbDynamic,
    dumbTopological,
    dumbRecursive,
    make,
    makeTrace,
    makeDirtyBit,
    shake,
    shakeDirtyBit,
    spreadsheet,
    spreadsheetTrace,
    spreadsheetRemote,
    bazel,
    shazel
    ) where

import Neil.Build
import Neil.Util
import Neil.Compute
import Control.Monad.Extra
import Data.Tuple.Extra
import Data.Default
import Data.Maybe
import Data.Either.Extra
import Debug.Trace
import Data.List
import Data.Typeable
import qualified Data.Set as Set
import qualified Data.Map as Map

---------------------------------------------------------------------
-- DEPENDENCY ORDER SCHEMES

topological :: Default i => (k -> [k] -> M i k v v -> M i k v ()) -> Build Applicative i k v
topological step compute k = runM $ do
    let depends = getDependencies compute
    forM_ (topSort depends $ transitiveClosure depends k) $ \k ->
        case compute getStore k of
            Nothing -> return ()
            Just act -> step k (depends k) act


newtype Recursive k = Recursive (Set.Set k)
    deriving Default

-- | Build a rule at most once in a single execution
recursive :: Default i => (k -> Maybe [k] -> (k -> M i k v v) -> M i k v ([k], v) -> M i k v ()) -> Build Monad i k v
recursive step compute = runM . ensure
    where
        ensure k = do
            let ask x = ensure x >> getStore x
            Recursive done <- getTemp
            when (k `Set.notMember` done) $ do
                modifyTemp $ \(Recursive set) -> Recursive $ Set.insert k set
                case trackDependencies compute ask k of
                    Nothing -> return ()
                    Just act -> step k (getDependenciesMaybe compute k) ask act


reordering
    :: (m ~ M (i, [k]) k v, Default i)
    => (k -> Maybe [k] -> (k -> m (Maybe v)) -> m (Either k ([k], v)) -> m (Maybe k)) -> Build Monad (i, [k]) k v
reordering step compute k = runM $ do
    order <- snd <$> getInfo
    order <- f Set.empty $ order ++ [k | k `notElem` order]
    modifyInfo $ second $ const order
    where
        f done [] = return []
        f done (k:ks) = do
            let f' x = if x `Set.member` done then Right <$> getStore x else return $ Left x
            case failDependencies compute f' k of
                Nothing -> (k :) <$> f (Set.insert k done) ks
                Just act -> do
                    res <- step k (getDependenciesMaybe compute k) (fmap eitherToMaybe . f') act
                    case res of
                        Nothing -> (k :) <$> f (Set.insert k done) ks
                        Just e -> f done $ [e | e `notElem` ks] ++ ks ++ [k]


---------------------------------------------------------------------
-- BUILD SYSTEMS


-- | Dumbest build system possible, always compute everything from scratch multiple times
dumb :: Build Monad () k v
dumb compute k = runM (f k)
    where f k = maybe (getStore k) (\act -> do v <- act; putStore k v; return v) $ compute f k

-- | Refinement of dumb, compute everything but at most once per execution
dumbRecursive :: Build Monad () k v
dumbRecursive = recursive $ \k _ _ act -> putStore k . snd =<< act

dumbTopological :: Build Applicative () k v
dumbTopological = topological $ \k _ act -> putStore k =<< act

dumbDynamic :: Build Monad ((), [k]) k v
dumbDynamic = reordering $ \k _ _ act -> do
    res <- act
    case res of
        Left e -> return $ Just e
        Right (_, v) -> do
            putStore k v
            return Nothing


-- | The simplified Make approach where we build a dependency graph and topological sort it
make :: Eq v => Build Applicative (Changed k v, ()) k v
make = withChangedApplicative $ topological $ \k ds act -> do
    kt <- getStoreTime k
    ds <- mapM getStoreTime ds
    let clean = all (< kt) ds
    when (not clean) $
        putStore k =<< act

makeDirtyBit :: Eq v => Build Applicative (Changed k v, ()) k v
makeDirtyBit = withChangedApplicative $ topological $ \k ds act -> do
    dirty <- getChanged k ||^ anyM getChanged ds
    when dirty $
        putStore k =<< act


type MakeHash k v = Map.Map (k, [Hash v]) (Hash v)


makeTrace :: Hashable v => Build Applicative (MakeHash k v) k v
makeTrace = topological $ \k ds act -> do
    now <- getStoreHash k
    ds <- mapM getStoreHash ds
    res <- Map.lookup (k, ds) <$> getInfo
    when (Just now /= res) $ do
        res <- act
        modifyInfo $ Map.insert (k, ds) (getHash res)
        putStore k res


shakeDirtyBit :: Eq v => Build Monad (Changed k v, ()) k v
shakeDirtyBit = withChangedMonad $ recursive $ \k ds ask act -> do
    dirty <- getChanged k ||^ maybe (return True) (anyM (\x -> ask x >> getChanged x)) ds
    when dirty $
        putStore k . snd =<< act


-- During the last execution, these were the traces I saw
type Shake k v = Map.Map k (Hash v, [(k, Hash v)])

-- | The simplified Shake approach of recording previous traces
shake :: Hashable v => Build Monad (Shake k v) k v
shake = recursive $ \k _ ask act -> do
    info <- getInfo
    valid <- case Map.lookup k info of
        Nothing -> return False
        Just (me, deps) ->
            ((==) me <$> getStoreHash k) &&^
            allM (\(d,h) -> (== h) . getHash <$> ask d) deps
    unless valid $ do
        (ds, v) <- act
        putStore k v
        dsh <- mapM getStoreHash ds
        modifyInfo $ Map.insert k (getHash v, zip ds dsh)


spreadsheetTrace :: (Hashable v) => Build Monad (Shake k v, [k]) k v
spreadsheetTrace = reordering $ \k ds ask act -> do
    info <- fst <$> getInfo
    valid <- case Map.lookup k info of
        Nothing -> return False
        Just (me, deps) ->
            ((==) me <$> getStoreHash k) &&^
            allM (\(d,h) -> (== Just h) . fmap getHash <$> ask d) deps
    if valid then
        return Nothing
    else do
        res <- act
        case res of
            Left e -> return $ Just e
            Right (ds, v) -> do
                putStore k v
                dsh <- mapM getStoreHash ds
                modifyInfo $ first $ Map.insert k (getHash v, zip ds dsh)
                return Nothing


spreadsheet :: Eq v => Build Monad (Changed k v, [k]) k v
spreadsheet = withChangedMonad $ reordering $ \k ds _ act -> do
    dirty <- getChanged k ||^ maybe (return True) (anyM getChanged) ds
    if not dirty then
        return Nothing
    else do
        res <- act
        case res of
            Left e -> return $ Just e
            Right (_, v) -> do
                putStore k v
                return Nothing

data Bazel k v = Bazel
    {bzKnown :: Map.Map (k, [Hash v]) (Hash v)
    ,bzContent :: Map.Map (Hash v) v
    } deriving Show

instance Default (Bazel k v) where def = Bazel def def

bazel :: Hashable v => Build Applicative (Bazel k v) k v
bazel = topological $ \k ds act -> do
    ds <- mapM getStoreHash ds
    res <- Map.lookup (k, ds) . bzKnown <$> getInfo
    case res of
        Nothing -> do
            res <- act
            modifyInfo $ \i -> i
                {bzKnown = Map.insert (k, ds) (getHash res) $ bzKnown i
                ,bzContent = Map.insert (getHash res) res $ bzContent i}
            putStore k res
        Just res -> do
            now <- getStoreHash k
            when (now /= res) $
                putStore k . (Map.! res) . bzContent =<< getInfo


data ShazelResult k v = ShazelResult [(k, Hash v)] (Hash v) deriving Show

data Shazel k v = Shazel
    {szKnown :: Map.Map k [ShazelResult k v]
    ,szContent :: Map.Map (Hash v) v
    } deriving Show

instance Default (Shazel k v) where def = Shazel def def

shazel :: Hashable v => Build Monad (Shazel k v) k v
shazel = recursive $ \k _ ask act -> do
    poss <- Map.findWithDefault [] k . szKnown <$> getInfo
    res <- flip filterM poss $ \(ShazelResult ds r) -> allM (\(k,h) -> (==) h . getHash <$> ask k) ds
    case res of
        [] -> do
            (ds, v) <- act
            dsv <- mapM getStoreHash ds
            modifyInfo $ \i -> i
                {szKnown = Map.insertWith (++) k [ShazelResult (zip ds dsv) (getHash v)] $ szKnown i
                ,szContent = Map.insert (getHash v) v $ szContent i}
            putStore k v
        _ -> do
            let poss = [v | ShazelResult _ v <- res]
            now <- getStoreHash k
            when (now `notElem` poss) $
                putStore k . (Map.! head poss) . szContent =<< getInfo


spreadsheetRemote :: Hashable v => Build Monad (Shazel k v, [k]) k v
spreadsheetRemote = reordering $ \k _ ask act -> do
    poss <- Map.findWithDefault [] k . szKnown . fst <$> getInfo
    res <- flip filterM poss $ \(ShazelResult ds r) -> allM (\(k,h) -> (== Just h) . fmap getHash <$> ask k) ds
    case res of
        [] -> do
            res <- act
            case res of
                Left e -> return $ Just e
                Right (ds, v) -> do
                    dsv <- mapM getStoreHash ds
                    modifyInfo $ first $ \i -> i
                        {szKnown = Map.insertWith (++) k [ShazelResult (zip ds dsv) (getHash v)] $ szKnown i
                        ,szContent = Map.insert (getHash v) v $ szContent i}
                    putStore k v
                    return Nothing
        _ -> do
            let poss = [v | ShazelResult _ v <- res]
            now <- getStoreHash k
            when (now `notElem` poss) $
                putStore k . (Map.! head poss) . szContent . fst =<< getInfo
            return Nothing
