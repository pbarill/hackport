module Status
    ( FileStatus(..)
    , fromStatus
    , status
    , statusAction
    ) where

import Action
import AnsiColor
import Bash
import P2
import Utils
import Overlays

import Control.Monad.State

import qualified Data.List as List

import qualified Data.ByteString.Lazy.Char8 as L

import Data.Char
import qualified Data.Map as Map
import Data.Map as Map (Map)

import qualified Data.Traversable as T


data FileStatus a
        = Same a
        | Differs a
        | OverlayOnly a
        | PortageOnly a
        deriving (Show,Eq)

instance Ord a => Ord (FileStatus a) where
    compare x y = compare (fromStatus x) (fromStatus y)

instance Functor FileStatus where
    fmap f st =
        case st of
            Same a -> Same (f a)
            Differs a -> Differs (f a)
            OverlayOnly a -> OverlayOnly (f a)
            PortageOnly a -> PortageOnly (f a)

fromStatus :: FileStatus a -> a
fromStatus fs =
    case fs of
        Same a -> a
        Differs a -> a
        OverlayOnly a -> a
        PortageOnly a -> a

status :: HPAction (Map Package [FileStatus Ebuild])
status = do
    portdir <- getPortdir
    overlayPath <- getOverlayPath
    overlay <- liftIO $ readPortageTree overlayPath
    portage <- liftIO $ readPortagePackages portdir (Map.keys overlay)
    let (over, both, port) = portageDiff overlay portage

    both' <- T.forM both $ mapM $ \e -> liftIO $ do
            -- can't fail, we know the ebuild exists in both portagedirs
            -- also, one of them is already bound to 'e'
            let (Just e1) = lookupEbuildWith portage (ePackage e) (comparing eVersion e)
                (Just e2) = lookupEbuildWith overlay (ePackage e) (comparing eVersion e)
            eq <- equals (eFilePath e1) (eFilePath e2)
            return $ if eq
                        then Same e
                        else Differs e

    let meld = Map.unionsWith (\a b -> List.sort (a++b))
                [ Map.map (map PortageOnly) port
                , both'
                , Map.map (map OverlayOnly) over
                ]
    return meld

statusAction :: HPAction ()
statusAction = status >>= statusPrinter

statusPrinter :: Map Package [FileStatus Ebuild] -> HPAction ()
statusPrinter packages = do
    liftIO $ putStrLn $ toColor (Same "Green") ++ ": package in portage and overlay are the same"
    liftIO $ putStrLn $ toColor (Differs "Yellow") ++ ": package in portage and overlay differs"
    liftIO $ putStrLn $ toColor (OverlayOnly "Red") ++ ": package only exist in the overlay"
    liftIO $ putStrLn $ toColor (PortageOnly "Magenta") ++ ": package only exist in the portage tree"
    forM_ (Map.toAscList packages) $ \(pkg, ebuilds) -> liftIO $ do
        let (P c p) = pkg
        putStr $ c ++ '/' : bold p
        putStr " "
        forM_ ebuilds $ \e -> do
            putStr $ toColor (fmap (show . eVersion) e)
            putChar ' '
        putStrLn ""

toColor :: FileStatus String -> String
toColor st = inColor c False Default (fromStatus st)
    where
    c = case st of
        (Same _) -> Green
        (Differs _) -> Yellow
        (OverlayOnly _) -> Red
        (PortageOnly _) -> Magenta

portageDiff :: Portage -> Portage -> (Portage, Portage, Portage)
portageDiff p1 p2 = (in1, ins, in2)
    where ins = Map.filter (not . null) $
                    Map.intersectionWith (List.intersectBy $ comparing eVersion) p1 p2
          in1 = difference p1 p2
          in2 = difference p2 p1
          difference x y = Map.filter (not . null) $
                       Map.differenceWith (\xs ys ->
                        let lst = foldr (List.deleteBy (comparing eVersion)) xs ys in
                        if null lst
                            then Nothing
                            else Just lst
                            ) x y

-- | Compares two ebuilds, returns True if they are equal.
--   Disregards comments.
equals :: FilePath -> FilePath -> IO Bool
equals fp1 fp2 = do
    f1 <- L.readFile fp1
    f2 <- L.readFile fp2
    return (equal' f1 f2)

equal' :: L.ByteString -> L.ByteString -> Bool
equal' = comparing essence
    where
    essence = filter (not . isEmpty) . filter (not . isComment) . L.lines
    isComment = L.isPrefixOf (L.pack "#") . L.dropWhile isSpace
    isEmpty = L.null . L.dropWhile isSpace

