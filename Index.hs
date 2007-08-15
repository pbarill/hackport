module Index where

import Data.List(isSuffixOf)
import Data.Maybe(mapMaybe)
import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Version (Version,parseVersion)
import Codec.Compression.GZip(decompress)
import Data.ByteString.Lazy.Char8(ByteString,unpack)
import Codec.Archive.Tar
import Distribution.PackageDescription
import Distribution.Package
import System.FilePath.Posix
import MaybeRead (readPMaybe)

type Index = [(String,String,PackageDescription)]
type IndexMap = Map.Map String (Set.Set Version)

readIndex :: ByteString -> Index
readIndex str = do
    let unziped = decompress str
        untared = readTarArchive unziped
    entr <- archiveEntries untared
    case splitDirectories (tarFileName (entryHeader entr)) of
        [".",pkgname,vers,file] -> do
            descr <- case parseDescription (unpack (entryData entr)) of
                ParseOk _ descr -> return descr
                _  -> error $ "Couldn't read cabal file "++show file
            return (pkgname,vers,descr)
        _ -> fail "doesn't look like the proper path"

searchIndex :: (String -> String -> Bool) -> Index -> [PackageDescription]
searchIndex f ind = map snd $ filter (uncurry f . fst) $ map (\(x,y,z) -> ((x,y),z)) ind

indexMapFromList :: [PackageIdentifier] -> IndexMap
indexMapFromList = foldl (\mp (PackageIdentifier {pkgName = name,pkgVersion = vers})
    -> Map.alter ((Just).(maybe (Set.singleton vers) (Set.insert vers))) name mp) Map.empty

indexToPackageIdentifier :: Index -> [PackageIdentifier]
indexToPackageIdentifier = mapMaybe (\(name,vers_str,_) -> do
    vers <- readPMaybe parseVersion vers_str
    return $ PackageIdentifier {pkgName = name,pkgVersion = vers})

bestVersions :: IndexMap -> Map.Map String Version
bestVersions = Map.map Set.findMax
