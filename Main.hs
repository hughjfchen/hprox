{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.ByteString.Char8       as BS8
import           Data.String                 (fromString)
import           Network                     (PortID (..), listenOn)
import qualified Network.HTTP.Client         as HC
import           Network.TLS                 as TLS
import           Network.Wai.Handler.Warp    (HostPreference, defaultSettings,
                                              runSettings, runSettingsSocket,
                                              setBeforeMainLoop, setHost,
                                              setNoParsePath, setPort,
                                              setServerName)
import           Network.Wai.Handler.WarpTLS (OnInsecure (..), onInsecure,
                                              runTLS, runTLSSocket,
                                              tlsServerHooks, tlsSettings)
import           Network.Wai.Middleware.Gzip (def, gzip)
import           System.Posix.User           (UserEntry (..),
                                              getUserEntryForName, setUserID)

import           Data.Maybe
import           Data.Monoid                 ((<>))
import           Options.Applicative

import           DumbApp                     (dumbApp)
import           HProx                       (ProxySettings (..), forceSSL,
                                              httpProxy)

data Opts = Opts
  { _bind :: Maybe HostPreference
  , _port :: Int
  , _ssl  :: [(String, CertFile)]
  , _user :: Maybe String
  , _auth :: Maybe FilePath
  , _ws   :: Maybe String
  }

data CertFile = CertFile
  { certfile :: FilePath
  , keyfile  :: FilePath
  }

readCert :: CertFile -> IO TLS.Credential
readCert (CertFile c k) = either error id <$> TLS.credentialLoadX509 c k

splitBy :: Eq a => a -> [a] -> [[a]]
splitBy _ [] = [[]]
splitBy c (x:xs)
  | c == x    = [] : splitBy c xs
  | otherwise = let y:ys = splitBy c xs in (x:y):ys

parser :: ParserInfo Opts
parser = info (helper <*> opts) fullDesc
  where
    parseSSL s = case splitBy ':' s of
        [host, cert, key] -> Right (host, CertFile cert key)
        _                 -> Left "invalid format for ssl certificates"

    opts = Opts <$> bind
                <*> (fromMaybe 3000 <$> port)
                <*> ssl
                <*> user
                <*> auth
                <*> ws

    bind = optional $ fromString <$> strOption
        ( long "bind"
       <> short 'b'
       <> metavar "bind_ip"
       <> help "The address to bind on (default: all interfaces)")

    port = optional $ option auto
        ( long "port"
       <> short 'p'
       <> metavar "port"
       <> help "port number (default 3000)")

    ssl = many $ option (eitherReader parseSSL)
        ( long "ssl"
       <> short 's'
       <> metavar "hostname:cerfile:keyfile"
       <> help "enable SSL and specify a SSL certificates")

    user = optional $ strOption
        ( long "user"
       <> short 'u'
       <> metavar "nobody"
       <> help "setuid after binding port")

    auth = optional $ strOption
        ( long "auth"
       <> short 'a'
       <> metavar "users.txt"
       <> help "password file for proxy authentication")

    ws = optional $ strOption
        ( long "ws"
       <> metavar "remote-host:80"
       <> help "remote host to handle websocket requests")


setuid :: String -> IO ()
setuid user = getUserEntryForName user >>= setUserID . userID

main :: IO ()
main = do
    opts <- execParser parser

    let certfiles = _ssl opts
    certs <- mapM (readCert.snd) certfiles

    let isSSL = not (null certfiles)
        (primaryHost, primaryCert) = head certfiles
        otherCerts = tail $ zip (map fst certfiles) certs

        settings = setNoParsePath True $
                   setServerName "Apache" $
                   maybe id (setBeforeMainLoop . setuid) (_user opts)
                   defaultSettings

        tlsset' = tlsSettings (certfile primaryCert) (keyfile primaryCert)
        hooks = (tlsServerHooks tlsset') { onServerNameIndication = onSNI }
        tlsset = tlsset' { tlsServerHooks = hooks, onInsecure = AllowInsecure }

        failSNI = fail "SNI" >> return mempty
        onSNI Nothing = failSNI
        onSNI (Just host)
          | host == primaryHost = return mempty
          | otherwise           = case lookup host otherCerts of
              Nothing   -> failSNI
              Just cert -> return (TLS.Credentials [cert])

        runner | isSSL     = runTLS tlsset
               | otherwise = runSettings
        runnerSocket | isSSL     = runTLSSocket tlsset
                     | otherwise = runSettingsSocket

    pauth <- case _auth opts of
        Nothing -> return Nothing
        Just f  -> Just . flip elem . filter (isJust . BS8.elemIndex ':') . BS8.lines <$> BS8.readFile f
    manager <- HC.newManager HC.defaultManagerSettings

    let pset = ProxySettings pauth Nothing (BS8.pack <$> _ws opts)
        proxy = (if isSSL then forceSSL else id) $ gzip def $ httpProxy pset manager dumbApp
        port = _port opts

    case _bind opts of
        Just hostp -> runner (setHost hostp $ setPort port settings) proxy
        Nothing    -> do
            socket <- listenOn (PortNumber $ fromIntegral port)
            runnerSocket settings socket proxy
