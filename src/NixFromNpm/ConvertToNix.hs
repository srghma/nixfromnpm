{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
module NixFromNpm.ConvertToNix where

import qualified Prelude as P
import qualified Data.HashMap.Strict as H
import Data.Text (Text, replace)
import Data.Fix

import NixFromNpm.Common hiding (replace)
import Nix.Types hiding (mkPath)
import qualified Nix.Types as Nix
import Nix.Parser
import NixFromNpm.NpmTypes
import NixFromNpm.SemVer

callPackage :: NExpr -> NExpr
callPackage = callPackageWith []

callPackageWith :: [Binding NExpr] -> NExpr -> NExpr
callPackageWith args e = mkApp (mkApp (mkSym "callPackage") e)
                               (mkNonRecSet args)

-- | Turns a string into one that can be used as an identifier.
fixName :: Name -> Name
fixName = replace "." "-"

-- | Converts a package name and semver into an identifier.
-- Example: "foo" and 1.2.3 turns into "foo_1-2-3".
-- Example: "foo.bar" and 1.2.3-baz turns into "foo-bar_1-2-3-baz"
toDepName :: Name -> SemVer -> Name
toDepName name (a, b, c, tags) = do
  let suffix = pack $ intercalate "-" $ (map show [a, b, c]) <> map unpack tags
  fixName name <> "_" <> suffix

-- | Converts a ResolvedDependency to a nix expression.
toNixExpr :: Name -> ResolvedDependency -> NExpr
toNixExpr name (Resolved semver) = mkSym $ toDepName name semver
toNixExpr name (Broken reason) = mkApp (mkSym "brokenPackage") $ mkNonRecSet
  [ "name" `bindTo` str name, "reason" `bindTo` str (pack $ show reason)]

-- | Gets the .nix filename of a semver. E.g. (0, 1, 2) -> 0.1.2.nix
toDotNix :: SemVer -> FilePath
toDotNix v = fromText $ renderSV v <> ".nix"

-- | Creates a doublequoted string from some text.
str :: Text -> NExpr
str = mkStr DoubleQuoted

-- | Converts distinfo into a nix fetchurl call.
distInfoToNix :: Maybe DistInfo -> NExpr
distInfoToNix Nothing = mkPath "./."
distInfoToNix (Just DistInfo{..}) = do
  let Success fetchurl = parseNixString "pkgs.fetchurl"
      (algo, hash) = case diShasum of
        SHA1 hash' -> ("sha1", hash')
        SHA256 hash' -> ("sha256", hash')
      bindings = ["url" `bindTo` str diUrl, algo `bindTo` str hash]
  fetchurl `mkApp` mkNonRecSet bindings

-- | Converts package meta to a nix expression, if it exists.
metaToNix :: PackageMeta -> Maybe NExpr
metaToNix PackageMeta{..} = do
  let
    grab name = maybe [] (\s -> [name `bindTo` str s])
    homepage = grab "homepage" (map uriToText pmHomepage)
    description = grab "description" pmDescription
    keywords = case pmKeywords of
      ks | null ks -> []
         | otherwise -> ["keywords" `bindTo` mkList (toList (map str ks))]
  case homepage <> description <> keywords of
    [] -> Nothing
    bindings -> Just $ mkNonRecSet bindings

-- | Converts a resolved package object into a nix expression. The expresion
-- will be a function where the arguments are its dependencies, and its result
-- is a call to `buildNodePackage`.
resolvedPkgToNix :: ResolvedPkg -> NExpr
resolvedPkgToNix ResolvedPkg{..} = do
  let -- Get a string representation of each dependency in name-version format.
      deps = map (uncurry toNixExpr) $ H.toList rpDependencies
      -- Same for dev dependencies.
      devDeps = map (uncurry toNixExpr) . H.toList <$> rpDevDependencies
      -- | List of arguments that these functions will take.
      funcParams' = ["pkgs", "nodePackages", "buildNodePackage",
                     "brokenPackage"]
      -- None of these have defaults, so put them into pairs with Nothing.
      funcParams = mkFormalSet $ map (\x -> (x, Nothing)) funcParams'
      -- Wrap an list expression in a `with nodePackages;` syntax if non-empty.
      withNodePackages list = case list of
        [] -> mkList []
        _ -> mkWith (mkSym "nodePackages") $ mkList list
  let args = mkNonRecSet $ catMaybes [
        Just $ "name" `bindTo` str rpName,
        Just $ "version" `bindTo` (str $ renderSV rpVersion),
        Just $ "src" `bindTo` distInfoToNix rpDistInfo,
        Just $ "deps" `bindTo` withNodePackages deps,
        bindTo "devDependencies" . withNodePackages <$> devDeps,
        bindTo "meta" <$> metaToNix rpMeta
        ]
  mkFunction funcParams $ mkSym "buildNodePackage" `mkApp` args


-- | Convenience function to generate an `import /path {args}` expression.
importWith :: Bool -- ^ True if the path is from the env, e.g. <nixpkgs>
           -> FilePath -- ^ Path to import
           -> [Binding NExpr] -- ^ Arguments to pass
           -> NExpr -- ^ The resulting nix expression
importWith isEnv path args = do
  mkSym "import" `mkApp` Nix.mkPath isEnv (pathToString path)
                 `mkApp` mkNonRecSet args

-- | We use this a few times: `import <nixpkgs> {}`
importNixpkgs :: NExpr
importNixpkgs = importWith True "nixpkgs" []

-- | Also used a few times, these are the top-level params to the generated
-- default.nix files.
defaultParams :: Formals NExpr
defaultParams = mkFormalSet [("pkgs", Just importNixpkgs),
                             ("nodejsVersion", Just $ str "4.1")]

-- | When passing through arguments, we inherit these two things.
defaultInherits :: [Binding NExpr]
defaultInherits = [Inherit Nothing $ map mkSelector ["pkgs", "nodejsVersion"]]

-- | The name of the subfolder within the output directory that
-- contains node packages.
nodePackagesDir :: FilePath
nodePackagesDir = "nodePackages"

bindRootPath :: Binding NExpr
bindRootPath = "rootPath" `bindTo` mkPath ("./" </> nodePackagesDir)

-- | The root-level default.nix file, which does not have any extensions.
rootDefaultNix :: NExpr
rootDefaultNix = mkFunction defaultParams body where
  nodeLibArgs = defaultInherits <> ["self" `bindTo` mkSym "nodeLib"]
  lets = ["nodeLib" `bindTo` importWith False "./nodeLib" nodeLibArgs]
  Success genPackages = parseNixString "nodeLib.generatePackages"
  body = mkLet lets $ mkApp genPackages (mkNonRecSet [bindRootPath])

-- | Creates the `default.nix` file that is the top-level expression we are
-- generating.
defaultNixExtending :: Name -- ^ Name of first extension.
                    -> Record FilePath -- ^ Extensions being included.
                    -> NExpr -- ^ A generated nix expression.
defaultNixExtending extName extensions = do
  mkFunction defaultParams body where
    -- Map over the expression map, creating a binding for each pair.
    lets = flip map (H.toList extensions) $ \(name, path) -> do
      -- Equiv. to `name = import /path {inherit pkgs nodejsVersion;}`
      name `bindTo` importWith False path defaultInherits
    args = [bindRootPath, "extensions" `bindTo`
              mkList (map mkSym (H.keys extensions))]
    genPkgs = extName <> ".nodeLib.generatePackages"
    Success generatePackages = parseNixString (unpack genPkgs)
    body = mkLet lets $ mkApp generatePackages (mkNonRecSet args)

-- | Create a `default.nix` file for a particular package.json; this simply
-- imports the package as defined in the given path, and calls into it.
mkPkgJsonDefaultNix :: FilePath -> NExpr
mkPkgJsonDefaultNix path = do
  mkFunction defaultParams $ importWith False path defaultInherits

bindingsToMap :: [Binding t] -> Record t
bindingsToMap = foldl' step mempty where
  step record binding = case binding of
    NamedVar [StaticKey key] obj -> H.insert key obj record
    _ -> record

-- | For expressions in a very specific format, we can ask them if their
-- dev dependencies have been defined.
nixExprHasDevDeps :: NExpr -> Maybe Bool -- ^ Nothing if we don't know
nixExprHasDevDeps (Fix nexpr) = case nexpr of
  -- It must be a function type
  NAbs params (Fix body) -> case body of
    -- Body must be a call to the `buildNodePackage` function
    NApp (Fix (NSym "buildNodePackage"))
         (Fix (NSet bindtype bindings)) -> do
      Just $ H.member "devDependencies" (bindingsToMap bindings)
    _ -> Nothing
  _ -> Nothing
