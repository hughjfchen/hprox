-- SPDX-License-Identifier: Apache-2.0
--
-- Copyright (C) 2023 Bin Jin. All Rights Reserved.

module Network.HProx.Impl
  ( ProxySettings (..)
  , forceSSL
  , healthCheckProvider
  , httpConnectProxy
  , httpGetProxy
  , httpProxy
  , logRequest
  , pacProvider
  , reverseProxy
  ) where

import Control.Applicative        ((<|>))
import Control.Concurrent.Async   (cancel, wait, waitEither, withAsync)
import Control.Exception          (SomeException, try)
import Control.Monad              (unless, void, when)
import Control.Monad.IO.Class     (liftIO)
import Data.Binary.Builder        qualified as BB
import Data.ByteString            qualified as BS
import Data.ByteString.Base64     (decodeLenient)
import Data.ByteString.Char8      qualified as BS8
import Data.ByteString.Lazy       qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.CaseInsensitive       qualified as CI
import Data.Conduit.Binary        qualified as CB
import Data.Conduit.Network       qualified as CN
import Network.HTTP.Client        qualified as HC
import Network.HTTP.ReverseProxy
    (ProxyDest (..), SetIpHeader (..), WaiProxyResponse (..),
    defaultWaiProxySettings, waiProxyToSettings, wpsSetIpHeader,
    wpsUpgradeToRaw)
import Network.HTTP.Types         qualified as HT
import Network.HTTP.Types.Header  qualified as HT
import System.Timeout             (timeout)

import Data.Conduit
import Data.Maybe
import Network.Wai
import Network.Wai.Middleware.StripHeaders

import Network.HProx.Log
import Network.HProx.Util

data ProxySettings = ProxySettings
  { proxyAuth     :: Maybe (BS.ByteString -> Bool)
  , passPrompt    :: Maybe BS.ByteString
  , wsRemote      :: Maybe BS.ByteString
  , revRemoteMap  :: [(BS.ByteString, BS.ByteString)]
  , hideProxyAuth :: Bool
  , naivePadding  :: Bool
  , logger        :: Logger
  }

logRequest :: Request -> LogStr
logRequest req = toLogStr (requestMethod req) <>
    " " <> hostname <> toLogStr (rawPathInfo req) <>
    " " <> toLogStr (show $ httpVersion req) <>
    " " <> (if isSecure req then "(tls) " else "")
    <> toLogStr (show $ remoteHost req)
  where
    isConnect = requestMethod req == "CONNECT"
    isGet = "http://" `BS.isPrefixOf` rawPathInfo req
    hostname | isConnect || isGet = ""
             | otherwise          = toLogStr (fromMaybe "(no-host)" $ requestHeaderHost req)

httpProxy :: ProxySettings -> HC.Manager -> Middleware
httpProxy set mgr = pacProvider . httpGetProxy set mgr . httpConnectProxy set

forceSSL :: ProxySettings -> Middleware
forceSSL pset app req respond
    | isSecure req               = app req respond
    | redirectWebsocket pset req = app req respond
    | otherwise                  = redirectToSSL req respond

redirectToSSL :: Application
redirectToSSL req respond
    | Just host <- requestHeaderHost req = respond $ responseKnownLength
        HT.status301
        [("Location", "https://" `BS.append` host)]
        ""
    | otherwise                          = respond $ responseKnownLength
        (HT.mkStatus 426 "Upgrade Required")
        [("Upgrade", "TLS/1.0, HTTP/1.1"), ("Connection", "Upgrade")]
        ""

isProxyHeader :: HT.HeaderName -> Bool
isProxyHeader h = "proxy" `BS.isPrefixOf` CI.foldedCase h

isForwardedHeader :: HT.HeaderName -> Bool
isForwardedHeader h = "x-forwarded" `BS.isPrefixOf` CI.foldedCase h

isCDNHeader :: HT.HeaderName -> Bool
isCDNHeader h = "cf-" `BS.isPrefixOf` CI.foldedCase h || h == "cdn-loop"

isToStripHeader :: HT.HeaderName -> Bool
isToStripHeader h = isProxyHeader h || isForwardedHeader h || isCDNHeader h || h == "X-Real-IP" || h == "X-Scheme"

checkAuth :: ProxySettings -> Request -> Bool
checkAuth ProxySettings{..} req
    | isNothing proxyAuth = True
    | isNothing authRsp   = False
    | otherwise           =
        pureLogger logger TRACE (authMsg <> " request (credential: " <> toLogStr decodedRsp <> ") from " <> toLogStr (show (remoteHost req))) authorized
  where
    authRsp = lookup HT.hProxyAuthorization (requestHeaders req)
    decodedRsp = decodeLenient $ snd $ BS8.spanEnd (/=' ') $ fromJust authRsp

    authorized = fromJust proxyAuth decodedRsp
    authMsg = if authorized then "authorized" else "unauthorized"

redirectWebsocket :: ProxySettings -> Request -> Bool
redirectWebsocket ProxySettings{..} req = wpsUpgradeToRaw defaultWaiProxySettings req && isJust wsRemote

proxyAuthRequiredResponse :: ProxySettings -> Response
proxyAuthRequiredResponse ProxySettings{..} = responseKnownLength
    HT.status407
    [(HT.hProxyAuthenticate, "Basic realm=\"" `BS.append` prompt `BS.append` "\"")]
    ""
  where
    prompt = fromMaybe "hprox" passPrompt

pacProvider :: Middleware
pacProvider fallback req respond
    | pathInfo req == [".hprox", "config.pac"],
      Just host' <- lookup "x-forwarded-host" (requestHeaders req) <|> requestHeaderHost req =
        let issecure = case lookup "x-forwarded-proto" (requestHeaders req) of
                Just proto -> proto == "https"
                Nothing    -> isSecure req
            scheme = if issecure then "HTTPS" else "PROXY"
            defaultPort = if issecure then ":443" else ":80"
            host | 58 `BS.elem` host' = host' -- ':'
                 | otherwise          = host' `BS.append` defaultPort
        in respond $ responseKnownLength
               HT.status200
               [("Content-Type", "application/x-ns-proxy-autoconfig")] $
               LBS8.unlines [ "function FindProxyForURL(url, host) {"
                            , LBS8.fromChunks ["  return \"", scheme, " ", host, "\";"]
                            , "}"
                            ]
    | otherwise = fallback req respond

healthCheckProvider :: Middleware
healthCheckProvider fallback req respond
    | pathInfo req == [".hprox", "health"] =
        respond $ responseKnownLength
            HT.status200
            [("Content-Type", "text/plain")]
            "okay"
    | otherwise = fallback req respond

reverseProxy :: ProxySettings -> HC.Manager -> Middleware
reverseProxy ProxySettings{..} mgr fallback =
    modifyResponse (stripHeaders ["Server", "Date"]) $
        waiProxyToSettings (return.proxyResponseFor) settings mgr
  where
    settings = defaultWaiProxySettings { wpsSetIpHeader = SIHNone }

    proxyResponseFor req = go revRemoteMap
      where
        go ((prefix, revRemote):left)
          | prefix `BS.isPrefixOf` rawPathInfo req =
            if revPort == 443
                then WPRModifiedRequestSecure nreq (ProxyDest revHost revPort)
                else WPRModifiedRequest nreq (ProxyDest revHost revPort)
          | otherwise = go left
          where
            (revHost, revPort) = parseHostPortWithDefault 80 revRemote
            nreq = req
              { requestHeaders = hdrs
              , requestHeaderHost = Just revHost
              , rawPathInfo = BS.drop (BS.length prefix - 1) (rawPathInfo req)
              }
            hdrs = (HT.hHost, revHost) : [ (hdn, hdv)
                                         | (hdn, hdv) <- requestHeaders req
                                         , not (isToStripHeader hdn) && hdn /= HT.hHost
                                         ]
        go _ = WPRApplication fallback

httpGetProxy :: ProxySettings -> HC.Manager -> Middleware
httpGetProxy pset@ProxySettings{..} mgr fallback = waiProxyToSettings (return.proxyResponseFor) settings mgr
  where
    settings = defaultWaiProxySettings { wpsSetIpHeader = SIHNone }

    proxyResponseFor req
        | redirectWebsocket pset req = wsWrapper (ProxyDest wsHost wsPort)
        | not isGETProxy             = WPRApplication fallback
        | checkAuth pset req         = WPRModifiedRequest nreq (ProxyDest host port)
        | hideProxyAuth              =
            pureLogger logger WARN ("unauthorized request (hidden without response): " <> logRequest req) $
            WPRApplication fallback
        | otherwise                  =
            pureLogger logger WARN ("unauthorized request: " <> logRequest req) $
            WPRResponse (proxyAuthRequiredResponse pset)
      where
        (wsHost, wsPort) = parseHostPortWithDefault 80 (fromJust wsRemote)
        wsWrapper = if wsPort == 443 then WPRProxyDestSecure else WPRProxyDest

        notCONNECT = requestMethod req /= "CONNECT"
        rawPath = rawPathInfo req
        rawPathPrefix = "http://"
        defaultPort = 80
        hostHeader = parseHostPortWithDefault defaultPort <$> requestHeaderHost req

        isRawPathProxy = rawPathPrefix `BS.isPrefixOf` rawPath
        hasProxyHeader = any (isProxyHeader.fst) (requestHeaders req)
        scheme = lookup "X-Scheme" (requestHeaders req)
        isHTTP2Proxy = HT.httpMajor (httpVersion req) >= 2 && scheme == Just "http" && isSecure req

        isGETProxy = notCONNECT && (isRawPathProxy || isHTTP2Proxy || isJust hostHeader && hasProxyHeader)

        nreq = req
          { rawPathInfo = newRawPath
          , requestHeaders = filter (not.isToStripHeader.fst) $ requestHeaders req
          }

        ((host, port), newRawPath)
            | isRawPathProxy  = (parseHostPortWithDefault defaultPort hostPortP, newRawPathP)
            | otherwise       = (fromJust hostHeader, rawPath)
          where
            (hostPortP, newRawPathP) = BS8.span (/='/') $
                BS.drop (BS.length rawPathPrefix) rawPath

httpConnectProxy :: ProxySettings -> Middleware
httpConnectProxy pset@ProxySettings{..} fallback req respond
    | not isConnectProxy = fallback req respond
    | checkAuth pset req = respondResponse
    | hideProxyAuth      = do
        logger WARN $ "unauthorized request (hidden without response): " <> logRequest req
        fallback req respond
    | otherwise          = do
        logger WARN $ "unauthorized request: " <> logRequest req
        respond (proxyAuthRequiredResponse pset)
  where
    hostPort' = parseHostPort (rawPathInfo req) <|> (requestHeaderHost req >>= parseHostPort)
    isConnectProxy = requestMethod req == "CONNECT" && isJust hostPort'

    Just (host, port) = hostPort'
    settings = CN.clientSettings port host

    backup = responseKnownLength HT.status500 [("Content-Type", "text/plain")]
        "HTTP CONNECT tunneling detected, but server does not support responseRaw"

    tryAndCatchAll :: IO a -> IO (Either SomeException a)
    tryAndCatchAll = try

    runStreams :: Int -> IO () -> IO () -> IO (Either SomeException ())
    runStreams secs left right = tryAndCatchAll $
        withAsync left $ \l -> do
            withAsync right $ \r -> do
                res1 <- waitEither l r
                let unfinished = case res1 of
                        Left _ -> r
                        _      -> l
                res2 <- timeout (secs * 1000000) (wait unfinished)
                when (isNothing res2) $ cancel unfinished

    respondResponse
        | HT.httpMajor (httpVersion req) < 2 = respond $ responseRaw (handleConnect True) backup
        | not naivePadding                   = respond $ responseStream HT.status200 [] streaming
        | otherwise                          = do
            padding <- randomPadding
            respond $ responseStream HT.status200 [("Padding", padding)] streaming
      where
        streaming write flush = do
            flush
            handleConnect False (getRequestBodyChunk req) (\bs -> write (BB.fromByteString bs) >> flush)

    maximumLength = 65535 - 3 - 255
    countPaddings = 8

    addStreamPadding = isJust (lookup "Padding" (requestHeaders req)) && naivePadding

    -- see: https://github.com/klzgrad/naiveproxy/#padding-protocol-an-informal-specification
    addPadding :: Int -> ConduitT BS.ByteString BS.ByteString IO ()
    addPadding 0 = awaitForever yield
    addPadding n = do
        mbs <- await
        case mbs of
            Nothing -> return ()
            Just bs | BS.null bs -> return ()
            Just bs -> do
                let (bs0, bs1) = BS.splitAt maximumLength bs
                unless (BS.null bs1) $ leftover bs1
                let len = BS.length bs0
                paddingLen <- liftIO randomPaddingLength
                let header = mconcat (map (BB.singleton.fromIntegral) [len `div` 256, len `mod` 256, paddingLen])
                    body   = BB.fromByteString bs0
                    tailer = BB.fromByteString (BS.replicate paddingLen 0)
                yield $ LBS.toStrict $ BB.toLazyByteString (header <> body <> tailer)
                addPadding (n - 1)

    removePadding :: Int -> ConduitT BS.ByteString BS.ByteString IO ()
    removePadding 0 = awaitForever yield
    removePadding n = do
        header <- CB.take 3
        case LBS.unpack header of
            [b0, b1, b2] -> do
                let len = fromIntegral b0 * 256 + fromIntegral b1
                    paddingLen = fromIntegral b2
                bs <- CB.take (fromIntegral (len + paddingLen))
                if LBS.length bs /= len + paddingLen
                    then return ()
                    else yield (LBS.toStrict $ LBS.take len bs) >> removePadding (n - 1)
            _ -> return ()

    yieldHttp1Response
        | naivePadding = do
            padding <- BB.fromByteString <$> liftIO randomPadding
            yield $ LBS.toStrict $ BB.toLazyByteString ("HTTP/1.1 200 OK\r\nPadding: " <> padding <> "\r\n\r\n")
        | otherwise    = yield "HTTP/1.1 200 OK\r\n\r\n"

    handleConnect :: Bool -> IO BS.ByteString -> (BS.ByteString -> IO ()) -> IO ()
    handleConnect http1 fromClient' toClient' = CN.runTCPClient settings $ \server ->
        let toServer = CN.appSink server
            fromServer = CN.appSource server
            fromClient = do
                bs <- liftIO fromClient'
                unless (BS.null bs) (yield bs >> fromClient)
            toClient = awaitForever (liftIO . toClient')

            clientToServer | addStreamPadding = fromClient .| removePadding countPaddings .| toServer
                           | otherwise        = fromClient .| toServer

            serverToClient | addStreamPadding = fromServer .| addPadding countPaddings .| toClient
                           | otherwise        = fromServer .| toClient
        in do
            when http1 $ runConduit $ yieldHttp1Response .| toClient
            -- gracefully close the other stream after 5 seconds if one side of stream is closed.
            void $ runStreams 5
                (runConduit clientToServer)
                (runConduit serverToClient)
