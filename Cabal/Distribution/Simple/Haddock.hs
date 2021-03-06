{-# LANGUAGE DeriveGeneric #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Haddock
-- Copyright   :  Isaac Jones 2003-2005
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This module deals with the @haddock@ and @hscolour@ commands.
-- It uses information about installed packages (from @ghc-pkg@) to find the
-- locations of documentation for dependent packages, so it can create links.
--
-- The @hscolour@ support allows generating HTML versions of the original
-- source, with coloured syntax highlighting.

module Distribution.Simple.Haddock (
  haddock, hscolour,

  haddockPackagePaths
  ) where

import qualified Distribution.Simple.GHC   as GHC
import qualified Distribution.Simple.GHCJS as GHCJS

-- local
import Distribution.Compat.Semigroup as Semi
import Distribution.Package
import qualified Distribution.ModuleName as ModuleName
import Distribution.PackageDescription as PD hiding (Flag)
import Distribution.Simple.Compiler hiding (Flag)
import Distribution.Simple.Program.GHC
import Distribution.Simple.Program
import Distribution.Simple.PreProcess
import Distribution.Simple.Setup
import Distribution.Simple.Build
import Distribution.Simple.InstallDirs
import Distribution.Simple.LocalBuildInfo hiding (substPathTemplate)
import Distribution.Simple.BuildPaths
import qualified Distribution.Simple.PackageIndex as PackageIndex
import qualified Distribution.InstalledPackageInfo as InstalledPackageInfo
import Distribution.InstalledPackageInfo ( InstalledPackageInfo )
import Distribution.Simple.Utils
import Distribution.System
import Distribution.Text
import Distribution.Utils.NubList
import Distribution.Version
import Distribution.Verbosity
import Language.Haskell.Extension


import Control.Monad    ( when, forM_ )
import Data.Char        ( isSpace )
import Data.Either      ( rights )
import Data.Foldable    ( traverse_, foldl' )
import Data.Maybe       ( fromMaybe, listToMaybe )
import GHC.Generics     ( Generic )

import System.Directory (doesFileExist)
import System.FilePath  ( (</>), (<.>)
                        , normalise, splitPath, joinPath, isAbsolute )
import System.IO        (hClose, hPutStr, hPutStrLn, hSetEncoding, utf8)

-- ------------------------------------------------------------------------------
-- Types

-- | A record that represents the arguments to the haddock executable, a product
-- monoid.
data HaddockArgs = HaddockArgs {
 argInterfaceFile :: Flag FilePath,
 -- ^ Path to the interface file, relative to argOutputDir, required.
 argPackageName :: Flag PackageIdentifier,
 -- ^ Package name, required.
 argHideModules :: (All,[ModuleName.ModuleName]),
 -- ^ (Hide modules ?, modules to hide)
 argIgnoreExports :: Any,
 -- ^ Ignore export lists in modules?
 argLinkSource :: Flag (Template,Template,Template),
 -- ^ (Template for modules, template for symbols, template for lines).
 argCssFile :: Flag FilePath,
 -- ^ Optional custom CSS file.
 argContents :: Flag String,
 -- ^ Optional URL to contents page.
 argVerbose :: Any,
 argOutput :: Flag [Output],
 -- ^ HTML or Hoogle doc or both? Required.
 argInterfaces :: [(FilePath, Maybe String)],
 -- ^ [(Interface file, URL to the HTML docs for links)].
 argOutputDir :: Directory,
 -- ^ Where to generate the documentation.
 argTitle :: Flag String,
 -- ^ Page title, required.
 argPrologue :: Flag String,
 -- ^ Prologue text, required.
 argGhcOptions :: Flag (GhcOptions, Version),
 -- ^ Additional flags to pass to GHC.
 argGhcLibDir :: Flag FilePath,
 -- ^ To find the correct GHC, required.
 argTargets :: [FilePath]
 -- ^ Modules to process.
} deriving Generic

-- | The FilePath of a directory, it's a monoid under '(</>)'.
newtype Directory = Dir { unDir' :: FilePath } deriving (Read,Show,Eq,Ord)

unDir :: Directory -> FilePath
unDir = joinPath . filter (\p -> p /="./" && p /= ".") . splitPath . unDir'

type Template = String

data Output = Html | Hoogle

-- ------------------------------------------------------------------------------
-- Haddock support

haddock :: PackageDescription
        -> LocalBuildInfo
        -> [PPSuffixHandler]
        -> HaddockFlags
        -> IO ()
haddock pkg_descr _ _ haddockFlags
  |    not (hasLibs pkg_descr)
    && not (fromFlag $ haddockExecutables haddockFlags)
    && not (fromFlag $ haddockTestSuites  haddockFlags)
    && not (fromFlag $ haddockBenchmarks  haddockFlags) =
      warn (fromFlag $ haddockVerbosity haddockFlags) $
           "No documentation was generated as this package does not contain "
        ++ "a library. Perhaps you want to use the --executables, --tests or"
        ++ " --benchmarks flags."

haddock pkg_descr lbi suffixes flags' = do
    let verbosity     = flag haddockVerbosity
        comp          = compiler lbi
        platform      = hostPlatform lbi

        flags
          | fromFlag (haddockForHackage flags') = flags'
            { haddockHoogle       = Flag True
            , haddockHtml         = Flag True
            , haddockHtmlLocation = Flag (pkg_url ++ "/docs")
            , haddockContents     = Flag (toPathTemplate pkg_url)
            , haddockHscolour     = Flag True
            }
          | otherwise = flags'
        pkg_url       = "/package/$pkg-$version"
        flag f        = fromFlag $ f flags

        tmpFileOpts   = defaultTempFileOptions
                       { optKeepTempFiles = flag haddockKeepTempFiles }
        htmlTemplate  = fmap toPathTemplate . flagToMaybe . haddockHtmlLocation
                        $ flags

    setupMessage verbosity "Running Haddock for" (packageId pkg_descr)
    (confHaddock, version, _) <-
      requireProgramVersion verbosity haddockProgram
        (orLaterVersion (Version [2,0] [])) (withPrograms lbi)

    -- various sanity checks
    when ( flag haddockHoogle
           && version < Version [2,2] []) $
         die "haddock 2.0 and 2.1 do not support the --hoogle flag."

    haddockGhcVersionStr <- rawSystemProgramStdout verbosity confHaddock
                              ["--ghc-version"]
    case (simpleParse haddockGhcVersionStr, compilerCompatVersion GHC comp) of
      (Nothing, _) -> die "Could not get GHC version from Haddock"
      (_, Nothing) -> die "Could not get GHC version from compiler"
      (Just haddockGhcVersion, Just ghcVersion)
        | haddockGhcVersion == ghcVersion -> return ()
        | otherwise -> die $
               "Haddock's internal GHC version must match the configured "
            ++ "GHC version.\n"
            ++ "The GHC version is " ++ display ghcVersion ++ " but "
            ++ "haddock is using GHC version " ++ display haddockGhcVersion

    -- the tools match the requests, we can proceed

    when (flag haddockHscolour) $
      hscolour' (warn verbosity) pkg_descr lbi suffixes
      (defaultHscolourFlags `mappend` haddockToHscolour flags)

    libdirArgs <- getGhcLibDir  verbosity lbi
    let commonArgs = mconcat
            [ libdirArgs
            , fromFlags (haddockTemplateEnv lbi (packageId pkg_descr)) flags
            , fromPackageDescription forDist pkg_descr ]
        forDist = fromFlagOrDefault False (haddockForHackage flags)

    withAllComponentsInBuildOrder pkg_descr lbi $ \component clbi -> do
      initialBuildSteps (flag haddockDistPref) pkg_descr lbi clbi verbosity
      preprocessComponent pkg_descr component lbi clbi False verbosity suffixes
      let
        doExe com = case (compToExe com) of
          Just exe -> do
            withTempDirectoryEx verbosity tmpFileOpts (buildDir lbi) "tmp" $
              \tmp -> do
                exeArgs <- fromExecutable verbosity tmp lbi exe clbi htmlTemplate
                           version
                let exeArgs' = commonArgs `mappend` exeArgs
                runHaddock verbosity tmpFileOpts comp platform
                  confHaddock exeArgs'
          Nothing -> do
           warn (fromFlag $ haddockVerbosity flags)
             "Unsupported component, skipping..."
           return ()
      case component of
        CLib lib -> do
          withTempDirectoryEx verbosity tmpFileOpts (buildDir lbi) "tmp" $
            \tmp -> do
              libArgs <- fromLibrary verbosity tmp lbi lib clbi htmlTemplate
                         version
              let libArgs' = commonArgs `mappend` libArgs
              runHaddock verbosity tmpFileOpts comp platform confHaddock libArgs'
        CExe   _ -> when (flag haddockExecutables) $ doExe component
        CTest  _ -> when (flag haddockTestSuites)  $ doExe component
        CBench _ -> when (flag haddockBenchmarks)  $ doExe component

    forM_ (extraDocFiles pkg_descr) $ \ fpath -> do
      files <- matchFileGlob fpath
      forM_ files $ copyFileTo verbosity (unDir $ argOutputDir commonArgs)

-- ------------------------------------------------------------------------------
-- Contributions to HaddockArgs.

fromFlags :: PathTemplateEnv -> HaddockFlags -> HaddockArgs
fromFlags env flags =
    mempty {
      argHideModules = (maybe mempty (All . not)
                        $ flagToMaybe (haddockInternal flags), mempty),
      argLinkSource = if fromFlag (haddockHscolour flags)
                               then Flag ("src/%{MODULE/./-}.html"
                                         ,"src/%{MODULE/./-}.html#%{NAME}"
                                         ,"src/%{MODULE/./-}.html#line-%{LINE}")
                               else NoFlag,
      argCssFile = haddockCss flags,
      argContents = fmap (fromPathTemplate . substPathTemplate env)
                    (haddockContents flags),
      argVerbose = maybe mempty (Any . (>= deafening))
                   . flagToMaybe $ haddockVerbosity flags,
      argOutput =
          Flag $ case [ Html | Flag True <- [haddockHtml flags] ] ++
                      [ Hoogle | Flag True <- [haddockHoogle flags] ]
                 of [] -> [ Html ]
                    os -> os,
      argOutputDir = maybe mempty Dir . flagToMaybe $ haddockDistPref flags
    }

fromPackageDescription :: Bool -> PackageDescription -> HaddockArgs
fromPackageDescription forDist pkg_descr =
      mempty { argInterfaceFile = Flag $ haddockName pkg_descr,
               argPackageName = Flag $ packageId $ pkg_descr,
               argOutputDir = Dir $ "doc" </> "html" </> name,
               argPrologue = Flag $ if null desc then synopsis pkg_descr
                                    else desc,
               argTitle = Flag $ showPkg ++ subtitle
             }
      where
        desc = PD.description pkg_descr
        showPkg = display (packageId pkg_descr)
        name
          | forDist = showPkg ++ "-docs"
          | otherwise = display (packageName pkg_descr)
        subtitle | null (synopsis pkg_descr) = ""
                 | otherwise                 = ": " ++ synopsis pkg_descr

componentGhcOptions :: Verbosity -> LocalBuildInfo
                 -> BuildInfo -> ComponentLocalBuildInfo -> FilePath
                 -> GhcOptions
componentGhcOptions verbosity lbi bi clbi odir =
  let f = case compilerFlavor (compiler lbi) of
            GHC   -> GHC.componentGhcOptions
            GHCJS -> GHCJS.componentGhcOptions
            _     -> error $
                       "Distribution.Simple.Haddock.componentGhcOptions:" ++
                       "haddock only supports GHC and GHCJS"
  in f verbosity lbi bi clbi odir

fromLibrary :: Verbosity
            -> FilePath
            -> LocalBuildInfo -> Library -> ComponentLocalBuildInfo
            -> Maybe PathTemplate -- ^ template for HTML location
            -> Version
            -> IO HaddockArgs
fromLibrary verbosity tmp lbi lib clbi htmlTemplate haddockVersion = do
    inFiles <- map snd `fmap` getLibSourceFiles lbi lib clbi
    ifaceArgs <- getInterfaces verbosity lbi clbi htmlTemplate
    let vanillaOpts = (componentGhcOptions normal lbi bi clbi (buildDir lbi)) {
                          -- Noooooooooo!!!!!111
                          -- haddock stomps on our precious .hi
                          -- and .o files. Workaround by telling
                          -- haddock to write them elsewhere.
                          ghcOptObjDir     = toFlag tmp,
                          ghcOptHiDir      = toFlag tmp,
                          ghcOptStubDir    = toFlag tmp
                      } `mappend` getGhcCppOpts haddockVersion bi
        sharedOpts = vanillaOpts {
                         ghcOptDynLinkMode = toFlag GhcDynamicOnly,
                         ghcOptFPic        = toFlag True,
                         ghcOptHiSuffix    = toFlag "dyn_hi",
                         ghcOptObjSuffix   = toFlag "dyn_o",
                         ghcOptExtra       =
                           toNubListR $ hcSharedOptions GHC bi

                     }
    opts <- if withVanillaLib lbi
            then return vanillaOpts
            else if withSharedLib lbi
            then return sharedOpts
            else die $ "Must have vanilla or shared libraries "
                       ++ "enabled in order to run haddock"
    ghcVersion <- maybe (die "Compiler has no GHC version")
                        return
                        (compilerCompatVersion GHC (compiler lbi))

    return ifaceArgs {
      argHideModules = (mempty,otherModules $ bi),
      argGhcOptions  = toFlag (opts, ghcVersion),
      argTargets     = inFiles
    }
  where
    bi = libBuildInfo lib

fromExecutable :: Verbosity
               -> FilePath
               -> LocalBuildInfo -> Executable -> ComponentLocalBuildInfo
               -> Maybe PathTemplate -- ^ template for HTML location
               -> Version
               -> IO HaddockArgs
fromExecutable verbosity tmp lbi exe clbi htmlTemplate haddockVersion = do
    inFiles <- map snd `fmap` getExeSourceFiles lbi exe clbi
    ifaceArgs <- getInterfaces verbosity lbi clbi htmlTemplate
    let vanillaOpts = (componentGhcOptions normal lbi bi clbi (buildDir lbi)) {
                          -- Noooooooooo!!!!!111
                          -- haddock stomps on our precious .hi
                          -- and .o files. Workaround by telling
                          -- haddock to write them elsewhere.
                          ghcOptObjDir  = toFlag tmp,
                          ghcOptHiDir   = toFlag tmp,
                          ghcOptStubDir = toFlag tmp
                      } `mappend` getGhcCppOpts haddockVersion bi
        sharedOpts = vanillaOpts {
                         ghcOptDynLinkMode = toFlag GhcDynamicOnly,
                         ghcOptFPic        = toFlag True,
                         ghcOptHiSuffix    = toFlag "dyn_hi",
                         ghcOptObjSuffix   = toFlag "dyn_o",
                         ghcOptExtra       =
                           toNubListR $ hcSharedOptions GHC bi
                     }
    opts <- if withVanillaLib lbi
            then return vanillaOpts
            else if withSharedLib lbi
            then return sharedOpts
            else die $ "Must have vanilla or shared libraries "
                       ++ "enabled in order to run haddock"
    ghcVersion <- maybe (die "Compiler has no GHC version")
                        return
                        (compilerCompatVersion GHC (compiler lbi))

    return ifaceArgs {
      argGhcOptions = toFlag (opts, ghcVersion),
      argOutputDir  = Dir (exeName exe),
      argTitle      = Flag (exeName exe),
      argTargets    = inFiles
    }
  where
    bi = buildInfo exe

compToExe :: Component -> Maybe Executable
compToExe comp =
  case comp of
    CTest test@TestSuite { testInterface = TestSuiteExeV10 _ f } ->
      Just Executable {
        exeName    = testName test,
        modulePath = f,
        buildInfo  = testBuildInfo test
      }
    CBench bench@Benchmark { benchmarkInterface = BenchmarkExeV10 _ f } ->
      Just Executable {
        exeName    = benchmarkName bench,
        modulePath = f,
        buildInfo  = benchmarkBuildInfo bench
      }
    CExe exe -> Just exe
    _ -> Nothing

getInterfaces :: Verbosity
              -> LocalBuildInfo
              -> ComponentLocalBuildInfo
              -> Maybe PathTemplate -- ^ template for HTML location
              -> IO HaddockArgs
getInterfaces verbosity lbi clbi htmlTemplate = do
    (packageFlags, warnings) <- haddockPackageFlags lbi clbi htmlTemplate
    traverse_ (warn verbosity) warnings
    return $ mempty {
                 argInterfaces = packageFlags
               }

getGhcCppOpts :: Version
              -> BuildInfo
              -> GhcOptions
getGhcCppOpts haddockVersion bi =
    mempty {
        ghcOptExtensions   = toNubListR [EnableExtension CPP | needsCpp],
        ghcOptCppOptions   = toNubListR defines
    }
  where
    needsCpp             = EnableExtension CPP `elem` usedExtensions bi
    defines              = [haddockVersionMacro]
    haddockVersionMacro  = "-D__HADDOCK_VERSION__="
                           ++ show (v1 * 1000 + v2 * 10 + v3)
      where
        [v1, v2, v3] = take 3 $ versionBranch haddockVersion ++ [0,0]

getGhcLibDir :: Verbosity -> LocalBuildInfo
             -> IO HaddockArgs
getGhcLibDir verbosity lbi = do
    l <- case compilerFlavor (compiler lbi) of
            GHC   -> GHC.getLibDir   verbosity lbi
            GHCJS -> GHCJS.getLibDir verbosity lbi
            _     -> error "haddock only supports GHC and GHCJS"
    return $ mempty { argGhcLibDir = Flag l }

-- ------------------------------------------------------------------------------
-- | Call haddock with the specified arguments.
runHaddock :: Verbosity
              -> TempFileOptions
              -> Compiler
              -> Platform
              -> ConfiguredProgram
              -> HaddockArgs
              -> IO ()
runHaddock verbosity tmpFileOpts comp platform confHaddock args = do
  let haddockVersion = fromMaybe (error "unable to determine haddock version")
                       (programVersion confHaddock)
  renderArgs verbosity tmpFileOpts haddockVersion comp platform args $
    \(flags,result)-> do

      rawSystemProgram verbosity confHaddock flags

      notice verbosity $ "Documentation created: " ++ result


renderArgs :: Verbosity
              -> TempFileOptions
              -> Version
              -> Compiler
              -> Platform
              -> HaddockArgs
              -> (([String], FilePath) -> IO a)
              -> IO a
renderArgs verbosity tmpFileOpts version comp platform args k = do
  let haddockSupportsUTF8          = version >= Version [2,14,4] []
      haddockSupportsResponseFiles = version >  Version [2,16,2] []
  createDirectoryIfMissingVerbose verbosity True outputDir
  withTempFileEx tmpFileOpts outputDir "haddock-prologue.txt" $
    \prologueFileName h -> do
          do
             when haddockSupportsUTF8 (hSetEncoding h utf8)
             hPutStrLn h $ fromFlag $ argPrologue args
             hClose h
             let pflag = "--prologue=" ++ prologueFileName
                 renderedArgs = pflag : renderPureArgs version comp platform args
             if haddockSupportsResponseFiles
               then
                 withTempFileEx tmpFileOpts outputDir "haddock-response.txt" $
                    \responseFileName hf -> do
                         when haddockSupportsUTF8 (hSetEncoding hf utf8)
                         let responseContents =
                                 unlines $ map escapeArg renderedArgs
                         hPutStr hf responseContents
                         hClose hf
                         info verbosity $ responseFileName ++ " contents: <<<"
                         info verbosity responseContents
                         info verbosity $ ">>> " ++ responseFileName
                         let respFile = "@" ++ responseFileName
                         k ([respFile], result)
               else
                 k (renderedArgs, result)
    where
      outputDir = (unDir $ argOutputDir args)
      result = intercalate ", "
             . map (\o -> outputDir </>
                            case o of
                              Html -> "index.html"
                              Hoogle -> pkgstr <.> "txt")
             $ arg argOutput
            where
              pkgstr = display $ packageName pkgid
              pkgid = arg argPackageName
      arg f = fromFlag $ f args
      -- Support a gcc-like response file syntax.  Each separate
      -- argument and its possible parameter(s), will be separated in the
      -- response file by an actual newline; all other whitespace,
      -- single quotes, double quotes, and the character used for escaping
      -- (backslash) are escaped.  The called program will need to do a similar
      -- inverse operation to de-escape and re-constitute the argument list.
      escape cs c
        |    isSpace c
          || '\\' == c
          || '\'' == c
          || '"'  == c = c:'\\':cs -- n.b., our caller must reverse the result
        | otherwise    = c:cs
      escapeArg = reverse . foldl' escape []

renderPureArgs :: Version -> Compiler -> Platform -> HaddockArgs -> [String]
renderPureArgs version comp platform args = concat
    [ (:[]) . (\f -> "--dump-interface="++ unDir (argOutputDir args) </> f)
      . fromFlag . argInterfaceFile $ args

    , if isVersion 2 16
        then (\pkg -> [ "--package-name=" ++ display (pkgName pkg)
                      , "--package-version="++display (pkgVersion pkg)
                      ])
             . fromFlag . argPackageName $ args
        else []

    , (\(All b,xs) -> bool (map (("--hide=" ++). display) xs) [] b)
                     . argHideModules $ args

    , bool ["--ignore-all-exports"] [] . getAny . argIgnoreExports $ args

    , maybe [] (\(m,e,l) ->
                 ["--source-module=" ++ m
                 ,"--source-entity=" ++ e]
                 ++ if isVersion 2 14 then ["--source-entity-line=" ++ l]
                    else []
               ) . flagToMaybe . argLinkSource $ args

    , maybe [] ((:[]) . ("--css="++)) . flagToMaybe . argCssFile $ args

    , maybe [] ((:[]) . ("--use-contents="++)) . flagToMaybe . argContents $ args

    , bool [] [verbosityFlag] . getAny . argVerbose $ args

    , map (\o -> case o of Hoogle -> "--hoogle"; Html -> "--html")
      . fromFlag . argOutput $ args

    , renderInterfaces . argInterfaces $ args

    , (:[]) . ("--odir="++) . unDir . argOutputDir $ args

    , (:[]) . ("--title="++)
      . (bool (++" (internal documentation)")
         id (getAny $ argIgnoreExports args))
      . fromFlag . argTitle $ args

    , [ "--optghc=" ++ opt | (opts, _ghcVer) <- flagToList (argGhcOptions args)
                           , opt <- renderGhcOptions comp platform opts ]

    , maybe [] (\l -> ["-B"++l]) $
      flagToMaybe (argGhcLibDir args) -- error if Nothing?

    , argTargets $ args
    ]
    where
      renderInterfaces =
        map (\(i,mh) -> "--read-interface=" ++
          maybe "" (++",") mh ++ i)
      bool a b c = if c then a else b
      isVersion major minor  = version >= Version [major,minor]  []
      verbosityFlag
       | isVersion 2 5 = "--verbosity=1"
       | otherwise     = "--verbose"

---------------------------------------------------------------------------------

-- | Given a list of 'InstalledPackageInfo's, return a list of interfaces and
-- HTML paths, and an optional warning for packages with missing documentation.
haddockPackagePaths :: [InstalledPackageInfo]
                    -> Maybe (InstalledPackageInfo -> FilePath)
                    -> IO ([(FilePath, Maybe FilePath)], Maybe String)
haddockPackagePaths ipkgs mkHtmlPath = do
  interfaces <- sequence
    [ case interfaceAndHtmlPath ipkg of
        Nothing -> return (Left (packageId ipkg))
        Just (interface, html) -> do
          exists <- doesFileExist interface
          if exists
            then return (Right (interface, html))
            else return (Left pkgid)
    | ipkg <- ipkgs, let pkgid = packageId ipkg
    , pkgName pkgid `notElem` noHaddockWhitelist
    ]

  let missing = [ pkgid | Left pkgid <- interfaces ]
      warning = "The documentation for the following packages are not "
             ++ "installed. No links will be generated to these packages: "
             ++ intercalate ", " (map display missing)
      flags = rights interfaces

  return (flags, if null missing then Nothing else Just warning)

  where
    -- Don't warn about missing documentation for these packages. See #1231.
    noHaddockWhitelist = map PackageName [ "rts" ]

    -- Actually extract interface and HTML paths from an 'InstalledPackageInfo'.
    interfaceAndHtmlPath :: InstalledPackageInfo
                         -> Maybe (FilePath, Maybe FilePath)
    interfaceAndHtmlPath pkg = do
      interface <- listToMaybe (InstalledPackageInfo.haddockInterfaces pkg)
      html <- case mkHtmlPath of
        Nothing -> fmap fixFileUrl
                        (listToMaybe (InstalledPackageInfo.haddockHTMLs pkg))
        Just mkPath -> Just (mkPath pkg)
      return (interface, if null html then Nothing else Just html)
      where
        -- The 'haddock-html' field in the hc-pkg output is often set as a
        -- native path, but we need it as a URL. See #1064.
        fixFileUrl f | isAbsolute f = "file://" ++ f
                     | otherwise    = f

haddockPackageFlags :: LocalBuildInfo
                    -> ComponentLocalBuildInfo
                    -> Maybe PathTemplate
                    -> IO ([(FilePath, Maybe FilePath)], Maybe String)
haddockPackageFlags lbi clbi htmlTemplate = do
  let allPkgs = installedPkgs lbi
      directDeps = map fst (componentPackageDeps clbi)
  transitiveDeps <- case PackageIndex.dependencyClosure allPkgs directDeps of
    Left x    -> return x
    Right inf -> die $ "internal error when calculating transitive "
                    ++ "package dependencies.\nDebug info: " ++ show inf
  haddockPackagePaths (PackageIndex.allPackages transitiveDeps) mkHtmlPath
    where
      mkHtmlPath                  = fmap expandTemplateVars htmlTemplate
      expandTemplateVars tmpl pkg =
        fromPathTemplate . substPathTemplate (env pkg) $ tmpl
      env pkg                     = haddockTemplateEnv lbi (packageId pkg)


haddockTemplateEnv :: LocalBuildInfo -> PackageIdentifier -> PathTemplateEnv
haddockTemplateEnv lbi pkg_id =
  (PrefixVar, prefix (installDirTemplates lbi))
  -- We want the legacy unit ID here, because it gives us nice paths
  -- (Haddock people don't care about the dependencies)
  : initialPathTemplateEnv pkg_id (mkLegacyUnitId pkg_id) (compilerInfo (compiler lbi))
  (hostPlatform lbi)

-- ------------------------------------------------------------------------------
-- hscolour support.

hscolour :: PackageDescription
         -> LocalBuildInfo
         -> [PPSuffixHandler]
         -> HscolourFlags
         -> IO ()
hscolour pkg_descr lbi suffixes flags = do
  hscolour' die pkg_descr lbi suffixes flags

hscolour' :: (String -> IO ()) -- ^ Called when the 'hscolour' exe is not found.
          -> PackageDescription
          -> LocalBuildInfo
          -> [PPSuffixHandler]
          -> HscolourFlags
          -> IO ()
hscolour' onNoHsColour pkg_descr lbi suffixes flags =
    either onNoHsColour (\(hscolourProg, _, _) -> go hscolourProg) =<<
      lookupProgramVersion verbosity hscolourProgram
      (orLaterVersion (Version [1,8] [])) (withPrograms lbi)
  where
    go :: ConfiguredProgram -> IO ()
    go hscolourProg = do
      setupMessage verbosity "Running hscolour for" (packageId pkg_descr)
      createDirectoryIfMissingVerbose verbosity True $
        hscolourPref distPref pkg_descr

      withAllComponentsInBuildOrder pkg_descr lbi $ \comp clbi -> do
        initialBuildSteps distPref pkg_descr lbi clbi verbosity
        preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
        let
          doExe com = case (compToExe com) of
            Just exe -> do
              let outputDir = hscolourPref distPref pkg_descr
                              </> exeName exe </> "src"
              runHsColour hscolourProg outputDir =<< getExeSourceFiles lbi exe clbi
            Nothing -> do
              warn (fromFlag $ hscolourVerbosity flags)
                "Unsupported component, skipping..."
              return ()
        case comp of
          CLib lib -> do
            let outputDir = hscolourPref distPref pkg_descr </> "src"
            runHsColour hscolourProg outputDir =<< getLibSourceFiles lbi lib clbi
          CExe   _ -> when (fromFlag (hscolourExecutables flags)) $ doExe comp
          CTest  _ -> when (fromFlag (hscolourTestSuites  flags)) $ doExe comp
          CBench _ -> when (fromFlag (hscolourBenchmarks  flags)) $ doExe comp

    stylesheet = flagToMaybe (hscolourCSS flags)

    verbosity  = fromFlag (hscolourVerbosity flags)
    distPref   = fromFlag (hscolourDistPref flags)

    runHsColour prog outputDir moduleFiles = do
         createDirectoryIfMissingVerbose verbosity True outputDir

         case stylesheet of -- copy the CSS file
           Nothing | programVersion prog >= Just (Version [1,9] []) ->
                       rawSystemProgram verbosity prog
                          ["-print-css", "-o" ++ outputDir </> "hscolour.css"]
                   | otherwise -> return ()
           Just s -> copyFileVerbose verbosity s (outputDir </> "hscolour.css")

         forM_ moduleFiles $ \(m, inFile) ->
             rawSystemProgram verbosity prog
                    ["-css", "-anchor", "-o" ++ outFile m, inFile]
        where
          outFile m = outputDir </>
                      intercalate "-" (ModuleName.components m) <.> "html"

haddockToHscolour :: HaddockFlags -> HscolourFlags
haddockToHscolour flags =
    HscolourFlags {
      hscolourCSS         = haddockHscolourCss flags,
      hscolourExecutables = haddockExecutables flags,
      hscolourTestSuites  = haddockTestSuites  flags,
      hscolourBenchmarks  = haddockBenchmarks  flags,
      hscolourVerbosity   = haddockVerbosity   flags,
      hscolourDistPref    = haddockDistPref    flags
    }
---------------------------------------------------------------------------------
-- TODO these should be moved elsewhere.

getLibSourceFiles :: LocalBuildInfo
                     -> Library
                     -> ComponentLocalBuildInfo
                     -> IO [(ModuleName.ModuleName, FilePath)]
getLibSourceFiles lbi lib clbi = getSourceFiles searchpaths modules
  where
    bi               = libBuildInfo lib
    modules          = PD.exposedModules lib ++ otherModules bi
    searchpaths      = autogenModulesDir lbi clbi : buildDir lbi : hsSourceDirs bi

getExeSourceFiles :: LocalBuildInfo
                     -> Executable
                     -> ComponentLocalBuildInfo
                     -> IO [(ModuleName.ModuleName, FilePath)]
getExeSourceFiles lbi exe clbi = do
    moduleFiles <- getSourceFiles searchpaths modules
    srcMainPath <- findFile (hsSourceDirs bi) (modulePath exe)
    return ((ModuleName.main, srcMainPath) : moduleFiles)
  where
    bi          = buildInfo exe
    modules     = otherModules bi
    searchpaths = autogenModulesDir lbi clbi : exeBuildDir lbi exe : hsSourceDirs bi

getSourceFiles :: [FilePath]
                  -> [ModuleName.ModuleName]
                  -> IO [(ModuleName.ModuleName, FilePath)]
getSourceFiles dirs modules = flip mapM modules $ \m -> fmap ((,) m) $
    findFileWithExtension ["hs", "lhs"] dirs (ModuleName.toFilePath m)
      >>= maybe (notFound m) (return . normalise)
  where
    notFound module_ = die $ "can't find source for module " ++ display module_

-- | The directory where we put build results for an executable
exeBuildDir :: LocalBuildInfo -> Executable -> FilePath
exeBuildDir lbi exe = buildDir lbi </> exeName exe </> exeName exe ++ "-tmp"

-- ------------------------------------------------------------------------------
-- Boilerplate Monoid instance.
instance Monoid HaddockArgs where
    mempty = gmempty
    mappend = (Semi.<>)

instance Semigroup HaddockArgs where
    (<>) = gmappend

instance Monoid Directory where
    mempty = Dir "."
    mappend = (Semi.<>)

instance Semigroup Directory where
    Dir m <> Dir n = Dir $ m </> n
