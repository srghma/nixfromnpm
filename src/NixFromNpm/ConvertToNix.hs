{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
module NixFromNpm.ConvertToNix where

import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as H
import Data.Map (Map)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T

import NixFromNpm.Common
import Nix.Types
import Nix.Parser
import Nix.Pretty (prettyNix)
import NixFromNpm.Options
import NixFromNpm.NpmTypes
import NixFromNpm.SemVer
import NixFromNpm.Parsers.SemVer
import NixFromNpm.PackageMap (PackageMap)
import NixFromNpm.NpmLookup (getPkg, FullyDefinedPackage(..), concatDots,
                             PreExistingPackage(..))

_startingSrc :: String
_startingSrc = "\
  \{nixpkgs ? import <nixpkgs> {}}:                                  \
  \let                                                               \
  \  inherit (nixpkgs.lib) attrValues foldl;                         \
  \  joinSets = foldl (a: b: a // b) {};                             \
  \  joinedExtensions = joinSets (attrValues extensions);            \
  \  allPkgs = nixpkgs // nodePkgs // joinedExtensions //            \
  \   {inherit (nixpkgs.nodePackages)buildNodePackage;};             \
  \  callPackage = nixpkgs.lib.callPackageWith allPkgs;              \
  \  nodePkgs = joinedExtensions // byVersion // defaults;           \
  \in                                                                \
  \nodePkgs"

_startingExpr :: NExpr
_startingExpr = case parseNixString _startingSrc of
  Success e -> e
  Failure e -> error $ unlines ["FATAL: Starting source failed to parse:",
                                show e]

callPackage :: NExpr -> NExpr
callPackage = callPackageWith []

callPackageWith :: [Binding NExpr] -> NExpr -> NExpr
callPackageWith args e = mkApp (mkApp (mkSym "callPackage") e)
                               (mkNonRecSet args)

callPackageWithRec :: [Binding NExpr] -> NExpr -> NExpr
callPackageWithRec args e = mkApp (mkApp (mkSym "callPackage") e)
                                  (mkRecSet args)

-- | Turns a string into one that can be used as an identifier.
fixName :: Name -> Name
fixName = T.replace "." "-"

-- | Converts a package name and semver into an identifier.
toDepName :: Name -> SemVer -> Name
toDepName name (a, b, c) = concat [fixName name, "_", pack $
                                   intercalate "-" $ map show [a, b, c]]
-- | Gets the .nix filename of a semver. E.g. (0, 1, 2) -> 0.1.2.nix
toDotNix :: SemVer -> Text
toDotNix v = concatDots v <> ".nix"

-- | Creates a doublequoted string from some text.
str :: Text -> NExpr
str = mkStr DoubleQuoted

-- | Converts distinfo into a nix fetchurl call.
distInfoToNix :: DistInfo -> NExpr
distInfoToNix DistInfo{..} = mkApp (mkSym "fetchurl") $ mkNonRecSet
  [ "url" `bindTo` str diUrl,
    "sha1" `bindTo`  str diShasum ]

-- | Tests if there is information in the package meta.
metaNotEmpty :: PackageMeta -> Bool
metaNotEmpty PackageMeta{..} = isJust pmDescription

-- | Converts package meta to a nix expression.
metaToNix :: PackageMeta -> NExpr
metaToNix PackageMeta{..} = case pmDescription of
  Nothing -> mkNonRecSet []
  Just d -> mkNonRecSet ["description" `bindTo` str d]

-- | Converts a resolved package object into a nix expression. The expresion
-- will be a function where the arguments are its dependencies, and its result
-- is a call to `buildNodePackage`.
resolvedPkgToNix :: ResolvedPkg -> NExpr
resolvedPkgToNix ResolvedPkg{..} = do
  let -- Get a string representation of each dependency in name-version format.
      deps = map (mkSym . uncurry toDepName) $ H.toList rpDependencies
      -- Get the parameters of the package function (deps + utility functions).
      _funcParams = map (uncurry toDepName) (H.toList rpDependencies)
                    <> ["buildNodePackage", "fetchurl"]
      -- None of these have defaults, so put them into pairs with Nothing.
      funcParams = mkFormalSet $ map (\x -> (x, Nothing)) _funcParams
  let args = mkNonRecSet $ catMaybes [
        Just $ "name" `bindTo` str rpName,
        Just $ "version" `bindTo` (str $ renderSV rpVersion),
        Just $ "src" `bindTo` distInfoToNix rpDistInfo,
        maybeIf (length deps > 0) $ "deps" `bindTo` mkList deps,
        maybeIf (metaNotEmpty rpMeta) $ "meta" `bindTo` metaToNix rpMeta
        ]
  mkFunction funcParams $ mkApp (mkSym "buildNodePackage") args

-- | Creates the `default.nix` file that is the top-level expression we are
-- generating.
mkDefaultNix :: Record [SemVer] -- ^ Map of names to versions of packages that
                                --   exist in this library.
             -> Record Path -- ^ Map of extensions being included.
             -> NExpr -- ^ A generated nix expression.
mkDefaultNix versionMap extensionMap = do
  let mkPath' = mkPath False . unpack
      toPath name ver = mkPath' $ concat ["./", name, "/", toDotNix ver]
      -- Make a set of all of the extensions
      extensionsSet = mkNonRecSet $
        -- Map over the expression map, creating a binding for each pair.
        flip map (H.toList extensionMap) $ \(name, path) ->
          name `bindTo` (mkApp
                          (mkApp (mkSym "import") (mkPath False (unpack path)))
                          (mkNonRecSet [Inherit Nothing [mkSelector "nixpkgs"]]))
      mkBinding name ver = toDepName name ver
                            `bindTo` callPackage (toPath name ver)
      mkBindings name vers = map (mkBinding name) vers
      mkDefVer name vers = case vers of
        [] -> errorC ["FATAL: no versions generated for package ", name]
        _  -> fixName name `bindTo` mkSym (toDepName name $ maximum vers)
      -- This bit of map gymnastics will create a list of pairs of names
      -- with all of the versions of that name that we have.
      versOnly = sortOn fst $ H.toList versionMap
      byVersion = mkNonRecSet $ concatMap (uncurry mkBindings) versOnly
      defaults = mkWith (mkSym "byVersion") $
        mkNonRecSet $ map (uncurry mkDefVer) versOnly
      newBindings = ["extensions" `bindTo` extensionsSet,
                     "byVersion" `bindTo` byVersion,
                     "defaults" `bindTo` defaults]
  modifyFunctionBody (appendBindings newBindings) _startingExpr

-- | The npm lookup utilities will produce a bunch of fully defined packages.
--   However, the only packages that we want to write are the new ones; that
--   is, the ones that we've discovered and the ones that already exist. This
--   will perform the appropriate filter.
takeNewPackages :: PackageMap FullyDefinedPackage
                -> (PackageMap ResolvedPkg, PackageMap NExpr)
takeNewPackages startingRec = do
  let isNew (NewPackage rpkg) = Just rpkg
      isNew _ = Nothing
      exists (FromExistingInOutput expr) = Just expr
      exists _ = Nothing
      newPkgs = H.map (modifyMap isNew) startingRec
      existingPkgs = H.map (modifyMap exists) startingRec
      removeEmpties = H.filter (not . H.null)
  (removeEmpties newPkgs, removeEmpties existingPkgs)

-- | Actually writes the packages to disk. Takes in the new packages to write,
--   and the names/paths to the libraries being extended.
dumpPkgs :: MonadIO m
         => String                 -- ^ Path to output directory.
         -> PackageMap ResolvedPkg -- ^ New packages being written.
         -> PackageMap NExpr       -- ^ Existing packages to be included
                                   --   in the generated default.nix.
         -> Record Path            -- ^ Libraries being extended.
         -> m ()
dumpPkgs path newPackages existingPackages extensions = liftIO $ do
  let _path = pack path
  -- If there aren't any new packages, we can stop here.
  if H.null newPackages
  then putStrLn "No new packages created." >> return ()
  else do
    putStrsLn ["Creating new packages at ", _path]
    createDirectoryIfMissing True path
    withDir path $ do
      -- Write the .nix file for each version of this package.
      forM_ (H.toList newPackages) $ \(pkgName, pkgVers) -> do
        let subdir = path </> unpack pkgName
        createDirectoryIfMissing False subdir
        withDir subdir $ forM_ (H.toList pkgVers) $ \(ver, rpkg) -> do
          let expr = resolvedPkgToNix rpkg
              fullPath = subdir </> unpack (toDotNix ver)
          putStrsLn ["Writing package file at ", pack fullPath]
          writeFile (unpack $ toDotNix ver) $ show $ prettyNix expr
      -- Write the default.nix file for the library.
      -- We need to build up a record mapping package names to the list of
      -- versions being defined in this library.
      let versionMap = map H.keys newPackages <> map H.keys existingPackages
          defaultNix = mkDefaultNix versionMap extensions
      writeFile "default.nix" $ show $ prettyNix defaultNix

-- | Given the path to a package, finds all of the .nix files which parse
--   correctly.
parseVersion :: Name -> Path -> IO (Maybe (SemVer, NExpr))
parseVersion pkgName path = do
  let pth = unpack path
      versionTxt = pack $ dropSuffix ".nix" $ takeBaseName pth
  case parseSemVer versionTxt of
    Left _ -> return Nothing -- not a version file
    Right version -> parseNixString . pack <$> readFile pth >>= \case
      Failure err -> do
        putStrsLn ["Warning: expression for ", pkgName, " version ",
                   versionTxt, " failed to parse:\n", pack $ show err]
        return Nothing -- invalid nix, should overwrite
      Success expr -> return $ Just (version, expr)

-- | Given the path to a file possibly containing nix expressions, finds all
--   expressions findable at that path and returns a map of them.
findExisting :: Maybe Name -- ^ Is `Just` if this is an extension.
             -> Path       -- ^ The path to search.
             -> IO (PackageMap PreExistingPackage) -- ^ Mapping of package
                                                   --   names to maps of
                                                   --   versions to nix
                                                   --   expressions.
findExisting maybeName path = do
  doesDirectoryExist (unpack path) >>= \case
    False -> case maybeName of
               Just name -> errorC ["Extension ", pack $ show name,
                                    " at path ", path, " does not exist."]
               Nothing -> return mempty
    True -> withDir (unpack path) $ do
      let wrapper :: NExpr -> PreExistingPackage
          wrapper = case maybeName of Nothing -> FromOutput
                                      Just name -> FromExtension name
      putStrsLn ["Searching for existing expressions in ", path, "..."]
      contents <- getDirectoryContents "."
      verMaps <- forM contents $ \dir -> do
        exprs <- doesDirectoryExist dir >>= \case
          True -> withDir dir $ do
            contents <- getDirectoryContents "."
            let files = pack <$> filter (endswith ".nix") contents
            catMaybes <$> mapM (parseVersion $ pack dir) files
          False -> do
            return mempty -- not a directory
        case exprs of
          [] -> return Nothing
          vs -> return $ Just (pack dir, H.map wrapper $ H.fromList exprs)
      let total = sum $ map (H.size . snd) $ catMaybes verMaps
      putStrsLn ["Found ", render total, " existing expressions"]
      return $ H.fromList $ catMaybes verMaps

-- | Given the output directory and any number of extensions to load,
-- finds any existing packages.
preloadPackages :: Bool        -- ^ Whether to skip the existence check.
                -> Path        -- ^ Output path to search for existing packages.
                -> Record Path -- ^ Mapping of names of libraries to extend,
                               --   and paths to those libraries.
                -> IO (PackageMap PreExistingPackage)
preloadPackages noExistCheck path toExtend = do
  existing <- if noExistCheck then pure mempty
              else findExisting Nothing path
  libraries <- fmap concat $ forM (H.toList toExtend) $ \(name, path) -> do
    findExisting (Just name) path
  return (existing <> libraries)

-- | Given the name of a package and a place to dump expressions to, generates
--   the expressions needed to build that package.
dumpPkgNamed :: Text        -- ^ The name of the package to fetch.
             -> Path        -- ^ The path to output to.
             -> PackageMap PreExistingPackage  -- ^ Set of existing packages.
             -> Record Path -- ^ Names -> paths of extensions.
             -> Maybe Text  -- ^ Optional github token.
             -> IO ()       -- ^ Writes files to a folder.
dumpPkgNamed name path existing extensions token = do
  pwd <- getCurrentDirectory
  packages <- getPkg name existing token
  let (new, existing) = takeNewPackages packages
  dumpPkgs (pwd </> unpack path) new existing extensions

-- | Parse the NAME=PATH extension directives.
getExtensions :: [Text] -> Record Path
getExtensions = foldl' step mempty where
  step :: Record Path -> Text -> Record Path
  step exts nameEqPath = case T.split (== '=') nameEqPath of
    [name, path] -> append name path
    [path] -> append (pack $ takeBaseName (unpack path)) path
    _ -> errorC ["Extensions must be of the form NAME=PATH (in argument ",
                 nameEqPath, ")"]
    where
      append name path = case H.lookup name exts of
        Nothing -> H.insert name path exts
        Just path' -> errorC ["Extension ", name, " is mapped to both path ",
                              path, " and path ", path']

-- displayExisting :: PackageMap -> IO ()
-- displayExisting pmap = forM_

dumpPkgFromOptions :: NixFromNpmOptions -> IO ()
dumpPkgFromOptions NixFromNpmOptions{..} = do
  forM_ nfnoPkgNames $ \name -> do
    let extensions = getExtensions nfnoExtendPaths
    existing <- preloadPackages nfnoNoCache nfnoOutputPath extensions
    -- displayExisting existing
    dumpPkgNamed name nfnoOutputPath existing extensions nfnoGithubToken
