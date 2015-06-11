{-# LANGUAGE RecordWildCards #-}

module Anchor.Tokens.Server (
    P.version,
    startServer,
    stopServer,
    startStore,
    ServerState(..),
    module X,
    ) where

import Data.ByteString (ByteString)
import           Control.Concurrent.Async
import           Control.Concurrent
import           Data.Pool
import qualified Data.Streaming.Network             as N
import           Database.PostgreSQL.Simple
import           Network.Wai.Handler.Warp           hiding (Connection)
import qualified Network.Socket                     as S
import           Pipes.Concurrent
import           Servant.Server
import           System.Log.Logger
import qualified System.Remote.Monitoring           as EKG

import           Anchor.Tokens.Server.API           as X
import           Anchor.Tokens.Server.Configuration as X
import           Anchor.Tokens.Server.Statistics    as X
import           Anchor.Tokens.Server.Types         as X

import           Paths_anchor_token_server          as P


--------------------------------------------------------------------------------

-- * Server

logName :: String
logName = "Anchor.Tokens.Server"

-- | Start the statistics-reporting thread.
startStatistics
    :: ServerOptions
    -> Pool Connection
    -> GrantCounters
    -> IO (Output GrantEvent, IO ())
startStatistics ServerOptions{..} connPool counters = do
    debugM logName $ "Starting EKG"
    srv <- EKG.forkServer optStatsHost optStatsPort
    (output, input, seal) <- spawn' (bounded 50)
    registerOAuth2Metrics (EKG.serverMetricStore srv) connPool input counters
    let stop = do
            debugM logName $ "Stopping EKG"
            atomically seal
            killThread (EKG.serverThreadId srv)
            threadDelay 10000
            debugM logName $ "Stopped EKG"
    return (output, stop)

startServer
    :: ServerOptions
    -> IO ServerState
startServer serverOpts@ServerOptions{..} = do
    debugM logName $ "Opening API Socket"
    sock <- N.bindPortTCP optServicePort optServiceHost
    let createConn = connectPostgreSQL optDBString
        destroyConn conn = close conn
        stripes = 1
        keep_alive = 10
        num_conns = 20
    serverPGConnPool <-
        createPool createConn destroyConn stripes keep_alive num_conns
    counters <- mkGrantCounters
    (serverEventSink, serverEventStop) <- startStatistics serverOpts serverPGConnPool counters
    let settings = setPort optServicePort $ setHost optServiceHost $ defaultSettings
    apiSrv <- async $ do
        debugM logName $ "Starting API Server"
        runSettingsSocket settings sock $ serve anchorOAuth2API server
    let serverServiceStop = do
            debugM logName $ "Closing API Socket"
            S.close sock
            async $ do
                wait apiSrv
                debugM logName $ "Stopped API Server"
    return ServerState{..}


stopServer :: ServerState -> IO (Async ())
stopServer ServerState{..} = do
    serverEventStop
    destroyAllResources serverPGConnPool
    serverServiceStop

--------------------------------------------------------------------------------

-- * Running parts of the token store

-- | Start a server that only has the local store, no UI, no EKG.
--
startStore :: ByteString -> IO ServerState
startStore dbstr = do
  let opts         = defaultServerOptions { optDBString = dbstr }
      dummySink    = Output (const $ return False)
      dummyStop    = return ()
      dummyService = async (return ())
  pool     <- createPool (connectPostgreSQL dbstr) close 1 1 1
  return (ServerState pool dummySink dummyStop opts dummyService)
