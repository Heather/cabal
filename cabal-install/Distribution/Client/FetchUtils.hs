-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.FetchUtils
-- Copyright   :  (c) David Himmelstrup 2005
--                    Duncan Coutts 2011
-- License     :  BSD-like
--
-- Maintainer  :  cabal-devel@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Functions for fetching packages
-----------------------------------------------------------------------------
{-# LANGUAGE RecordWildCards #-}
module Distribution.Client.FetchUtils (

    -- * fetching packages
    fetchPackage,
    isFetched,
    checkFetched,

    -- ** specifically for repo packages
    checkRepoTarballFetched,
    fetchRepoTarball,

    -- * fetching other things
    downloadIndex,
  ) where

import Distribution.Client.Types
import Distribution.Client.HttpUtils
         ( downloadURI, isOldHackageURI, DownloadResult(..)
         , HttpTransport(..), transportCheckHttps, remoteRepoCheckHttps )

import Distribution.Package
         ( PackageId, packageName, packageVersion )
import Distribution.Simple.Utils
         ( notice, info, setupMessage )
import Distribution.Text
         ( display )
import Distribution.Verbosity
         ( Verbosity )
import Distribution.Client.GlobalFlags
         ( RepoContext(..) )

import Data.Maybe
import System.Directory
         ( doesFileExist, createDirectoryIfMissing, getTemporaryDirectory )
import System.IO
         ( openTempFile, hClose )
import System.FilePath
         ( (</>), (<.>) )
import qualified System.FilePath.Posix as FilePath.Posix
         ( combine, joinPath )
import Network.URI
         ( URI(uriPath) )

import qualified Hackage.Security.Client as Sec

-- ------------------------------------------------------------
-- * Actually fetch things
-- ------------------------------------------------------------

-- | Returns @True@ if the package has already been fetched
-- or does not need fetching.
--
isFetched :: UnresolvedPkgLoc -> IO Bool
isFetched loc = case loc of
    LocalUnpackedPackage _dir       -> return True
    LocalTarballPackage  _file      -> return True
    RemoteTarballPackage _uri local -> return (isJust local)
    RepoTarballPackage repo pkgid _ -> doesFileExist (packageFile repo pkgid)

-- | Checks if the package has already been fetched (or does not need
-- fetching) and if so returns evidence in the form of a 'PackageLocation'
-- with a resolved local file location.
--
checkFetched :: UnresolvedPkgLoc
             -> IO (Maybe ResolvedPkgLoc)
checkFetched loc = case loc of
    LocalUnpackedPackage dir  ->
      return (Just $ LocalUnpackedPackage dir)
    LocalTarballPackage  file ->
      return (Just $ LocalTarballPackage  file)
    RemoteTarballPackage uri (Just file) ->
      return (Just $ RemoteTarballPackage uri file)
    RepoTarballPackage repo pkgid (Just file) ->
      return (Just $ RepoTarballPackage repo pkgid file)

    RemoteTarballPackage _uri Nothing -> return Nothing
    RepoTarballPackage repo pkgid Nothing ->
      fmap (fmap (RepoTarballPackage repo pkgid))
           (checkRepoTarballFetched repo pkgid)


-- | Like 'checkFetched' but for the specific case of a 'RepoTarballPackage'.
--
checkRepoTarballFetched :: Repo -> PackageId -> IO (Maybe FilePath)
checkRepoTarballFetched repo pkgid = do
    let file = packageFile repo pkgid
    exists <- doesFileExist file
    if exists
      then return (Just file)
      else return Nothing


-- | Fetch a package if we don't have it already.
--
fetchPackage :: Verbosity
             -> RepoContext
             -> UnresolvedPkgLoc
             -> IO ResolvedPkgLoc
fetchPackage verbosity repoCtxt loc = case loc of
    LocalUnpackedPackage dir  ->
      return (LocalUnpackedPackage dir)
    LocalTarballPackage  file ->
      return (LocalTarballPackage  file)
    RemoteTarballPackage uri (Just file) ->
      return (RemoteTarballPackage uri file)
    RepoTarballPackage repo pkgid (Just file) ->
      return (RepoTarballPackage repo pkgid file)

    RemoteTarballPackage uri Nothing -> do
      path <- downloadTarballPackage uri
      return (RemoteTarballPackage uri path)
    RepoTarballPackage repo pkgid Nothing -> do
      local <- fetchRepoTarball verbosity repoCtxt repo pkgid
      return (RepoTarballPackage repo pkgid local)
  where
    downloadTarballPackage uri = do
      transport <- repoContextGetTransport repoCtxt
      transportCheckHttps transport uri
      notice verbosity ("Downloading " ++ show uri)
      tmpdir <- getTemporaryDirectory
      (path, hnd) <- openTempFile tmpdir "cabal-.tar.gz"
      hClose hnd
      _ <- downloadURI transport verbosity uri path
      return path


-- | Fetch a repo package if we don't have it already.
--
fetchRepoTarball :: Verbosity -> RepoContext -> Repo -> PackageId -> IO FilePath
fetchRepoTarball verbosity repoCtxt repo pkgid = do
  fetched <- doesFileExist (packageFile repo pkgid)
  if fetched
    then do info verbosity $ display pkgid ++ " has already been downloaded."
            return (packageFile repo pkgid)
    else do setupMessage verbosity "Downloading" pkgid
            downloadRepoPackage
  where
    downloadRepoPackage = case repo of
      RepoLocal{..} -> return (packageFile repo pkgid)

      RepoRemote{..} -> do
        transport <- repoContextGetTransport repoCtxt
        remoteRepoCheckHttps transport repoRemote
        let uri  = packageURI  repoRemote pkgid
            dir  = packageDir  repo       pkgid
            path = packageFile repo       pkgid
        createDirectoryIfMissing True dir
        _ <- downloadURI transport verbosity uri path
        return path

      RepoSecure{} -> repoContextWithSecureRepo repoCtxt repo $ \rep -> do
        let dir  = packageDir  repo pkgid
            path = packageFile repo pkgid
        createDirectoryIfMissing True dir
        Sec.uncheckClientErrors $ do
          info verbosity ("writing " ++ path)
          Sec.downloadPackage' rep pkgid path
        return path

-- | Downloads an index file to [config-dir/packages/serv-id].
--
downloadIndex :: HttpTransport -> Verbosity -> RemoteRepo -> FilePath -> IO DownloadResult
downloadIndex transport verbosity remoteRepo cacheDir = do
  remoteRepoCheckHttps transport remoteRepo
  let uri = (remoteRepoURI remoteRepo) {
              uriPath = uriPath (remoteRepoURI remoteRepo)
                          `FilePath.Posix.combine` "00-index.tar.gz"
            }
      path = cacheDir </> "00-index" <.> "tar.gz"
  createDirectoryIfMissing True cacheDir
  downloadURI transport verbosity uri path


-- ------------------------------------------------------------
-- * Path utilities
-- ------------------------------------------------------------

-- | Generate the full path to the locally cached copy of
-- the tarball for a given @PackageIdentifer@.
--
packageFile :: Repo -> PackageId -> FilePath
packageFile repo pkgid = packageDir repo pkgid
                     </> display pkgid
                     <.> "tar.gz"

-- | Generate the full path to the directory where the local cached copy of
-- the tarball for a given @PackageIdentifer@ is stored.
--
packageDir :: Repo -> PackageId -> FilePath
packageDir repo pkgid = repoLocalDir repo
                    </> display (packageName    pkgid)
                    </> display (packageVersion pkgid)

-- | Generate the URI of the tarball for a given package.
--
packageURI :: RemoteRepo -> PackageId -> URI
packageURI repo pkgid | isOldHackageURI (remoteRepoURI repo) =
  (remoteRepoURI repo) {
    uriPath = FilePath.Posix.joinPath
      [uriPath (remoteRepoURI repo)
      ,display (packageName    pkgid)
      ,display (packageVersion pkgid)
      ,display pkgid <.> "tar.gz"]
  }
packageURI repo pkgid =
  (remoteRepoURI repo) {
    uriPath = FilePath.Posix.joinPath
      [uriPath (remoteRepoURI repo)
      ,"package"
      ,display pkgid <.> "tar.gz"]
  }
