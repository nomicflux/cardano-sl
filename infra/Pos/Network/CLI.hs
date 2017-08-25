{-# LANGUAGE CPP #-}

-- following Pos.Util.UserSecret
#if !defined(mingw32_HOST_OS)
#define POSIX
#endif

-- | Command line interface for specifying the network config
module Pos.Network.CLI (
    NetworkConfigOpts(..)
  , NetworkConfigException(..)
  , networkConfigOption
  , ipv4ToNetworkAddress
  , intNetworkConfigOpts
    -- * Exported primilary for testing
  , readTopology
  , readPolicies
  , fromPovOf
  ) where

import           Control.Concurrent
import           Control.Exception               (Exception (..))
import qualified Data.ByteString.Char8           as BS.C8
import           Data.IP                         (IPv4)
import qualified Data.Map.Strict                 as M
import           Data.Maybe                      (fromJust, mapMaybe)
import qualified Data.Yaml                       as Yaml
import           Formatting                      (sformat, shown, (%))
import           Mockable                        (Catch, Mockable, Throw, fork, throw,
                                                  try)
import           Mockable.Concurrent
import           Network.Broadcast.OutboundQueue (Alts, Peers, peersFromList)
import qualified Network.DNS                     as DNS
import qualified Options.Applicative             as Opt
import qualified Pos.DHT.Real.Param              as DHT (KademliaParams,
                                                         MalformedDHTKey (..),
                                                         fromYamlConfig)
import           Pos.Network.DnsDomains          (DnsDomains (..), NodeAddr (..))
import           Pos.Network.Types               (NodeId, NodeName (..))
import qualified Pos.Network.Types               as T
import           Pos.Network.Yaml                (NodeMetadata (..))
import qualified Pos.Network.Yaml                as Y
import           Pos.Util.TimeWarp               (NetworkAddress, addressToNodeId)
import           System.Wlog.CanLog              (WithLogger, logError, logNotice)
import           Universum

#ifdef POSIX
import           Pos.Util.SigHandler             (Signal (..), installHandler)
#endif

{-------------------------------------------------------------------------------
  Command line arguments
-------------------------------------------------------------------------------}

data NetworkConfigOpts = NetworkConfigOpts {
      -- | Filepath to .yaml file with the network topology
      networkConfigOptsTopology :: Maybe FilePath

    , networkConfigOptsKademlia :: Maybe FilePath

      -- | Name of the current node
    , networkConfigOptsSelf     :: Maybe NodeName

      -- | Port number to use when translating IP addresses to NodeIds
    , networkConfigOptsPort     :: Word16

    , networkConfigOptsPolicies :: Maybe FilePath
    }
  deriving (Show)

{-------------------------------------------------------------------------------
  Parser
-------------------------------------------------------------------------------}

networkConfigOption :: Opt.Parser NetworkConfigOpts
networkConfigOption = NetworkConfigOpts
    <$> (optional . Opt.strOption $ mconcat [
            Opt.long "topology"
          , Opt.metavar "FILEPATH"
          , Opt.help "Path to a YAML file containing the network topology"
          ])
    <*> (optional . Opt.strOption $ mconcat [
            Opt.long "kademlia"
          , Opt.metavar "FILEPATH"
          , Opt.help "Path to a YAML file containing the kademlia configuration"
          ])
    <*> (optional . Opt.option (fromString <$> Opt.str) $ mconcat [
            Opt.long "node-id"
          , Opt.metavar "NODE_ID"
          , Opt.help "Identifier for this node within the network"
          ])
    <*> (Opt.option Opt.auto $ mconcat [
            Opt.long "default-port"
          , Opt.metavar "PORT"
          , Opt.help "Port number for IP address to node ID translation"
          , Opt.value 3000
          ])
    <*> (Opt.optional . Opt.strOption $ mconcat [
            Opt.long "policies"
          , Opt.metavar "FILEPATH"
          , Opt.help "Path to a YAML file containing the network policies"
          ])

{-------------------------------------------------------------------------------
  Defaults
-------------------------------------------------------------------------------}

-- | The topology we assume when no topology file is specified
defaultTopology :: Y.Topology
defaultTopology = Y.TopologyBehindNAT {
      topologyValency    = 1
    , topologyFallbacks  = 1
    , topologyDnsDomains = defaultDnsDomains
    }

-- | The default DNS domains used for relay discovery
--
-- TODO: Give this a proper value
defaultDnsDomains :: DnsDomains DNS.Domain
defaultDnsDomains = DnsDomains [
      [NodeAddrDNS "todo.defaultDnsDomain.com" Nothing]
    ]

{-------------------------------------------------------------------------------
  Monitor for static peers
-------------------------------------------------------------------------------}

data MonitorEvent m =
    MonitorRegister (Peers NodeId -> m ())
  | MonitorSIGHUP

-- | Monitor for changes to the static config
monitorStaticConfig :: forall m. (
                         WithLogger     m
                       , MonadIO        m
                       , Mockable Fork  m
                       , Mockable Catch m
                       )
                    => NetworkConfigOpts
                    -> NodeMetadata    -- ^ Original metadata (at startup)
                    -> Peers NodeId    -- ^ Initial value
                    -> m T.StaticPeers
monitorStaticConfig cfg@NetworkConfigOpts{..} origMetadata initPeers = do
    events :: Chan (MonitorEvent m) <- liftIO $ newChan

    let loop :: Peers NodeId
             -> [Peers NodeId -> m ()]
             -> m ()
        loop peers handlers = do
          event <- liftIO $ readChan events
          case event of
            MonitorRegister handler -> do
              runHandler peers handler -- Call new handler with current value
              loop peers (handler:handlers)
            MonitorSIGHUP -> do
              let fp = fromJust networkConfigOptsTopology
              mParsedTopology <- try $ liftIO $ readTopology fp
              case mParsedTopology of
                Right (Y.TopologyStatic allPeers) -> do
                  (newMetadata, newPeers, _) <-
                    liftIO $ fromPovOf cfg allPeers

                  unless (nmType newMetadata == nmType origMetadata) $
                    logError $ changedType fp
                  unless (nmKademlia newMetadata == nmKademlia origMetadata) $
                    logError $ changedKademlia fp
                  unless (nmMaxSubscrs newMetadata == nmMaxSubscrs origMetadata) $
                    logError $ changedMaxSubscrs fp

                  mapM_ (runHandler newPeers) handlers
                  logNotice $ sformat "SIGHUP: Re-read topology"
                  loop newPeers handlers
                Right _otherTopology -> do
                  logError $ changedFormat fp
                  loop peers handlers
                Left ex -> do
                  logError $ readFailed fp ex
                  loop peers handlers

#ifdef POSIX
    liftIO $ installHandler SigHUP $ writeChan events MonitorSIGHUP
#endif

    _tid <- fork $ loop initPeers []
    return T.StaticPeers {
        T.staticPeersOnChange = writeChan events . MonitorRegister
      }
  where
    runHandler :: forall t . t -> (t -> m ()) -> m ()
    runHandler it handler = do
        mu <- try (handler it)
        case mu of
          Left  ex -> logError $ handlerError ex
          Right () -> return ()

    changedFormat, changedType, changedKademlia :: FilePath -> Text
    changedFormat     = sformat $ "SIGHUP (" % shown % "): Cannot dynamically change topology."
    changedType       = sformat $ "SIGHUP (" % shown % "): Cannot dynamically change own node type."
    changedKademlia   = sformat $ "SIGHUP (" % shown % "): Cannot dynamically start/stop Kademlia."
    changedMaxSubscrs = sformat $ "SIGHUP (" % shown % "): Cannot dynamically change maximum number of subscribers."

    readFailed :: FilePath -> SomeException -> Text
    readFailed = sformat $ "SIGHUP: Failed to read " % shown % ": " % shown % ". Ignored."

    handlerError :: SomeException -> Text
    handlerError = sformat $ "Exception thrown by staticPeersOnChange handler: " % shown % ". Ignored."

{-------------------------------------------------------------------------------
  Interpreter
-------------------------------------------------------------------------------}

-- | Interpreter for the network config opts
intNetworkConfigOpts :: forall m. (
                         WithLogger     m
                       , MonadIO        m
                       , Mockable Fork  m
                       , Mockable Catch m
                       , Mockable Throw m
                       )
                     => NetworkConfigOpts
                     -> m (T.NetworkConfig DHT.KademliaParams)
intNetworkConfigOpts cfg@NetworkConfigOpts{..} = do
    parsedTopology <- case networkConfigOptsTopology of
                        Nothing -> return defaultTopology
                        Just fp -> liftIO $ readTopology fp
    ourTopology <- case parsedTopology of
      Y.TopologyStatic{..} -> do
        (md@NodeMetadata{..}, initPeers, kademliaPeers) <- liftIO $ fromPovOf cfg topologyAllPeers
        topologyStaticPeers <- monitorStaticConfig cfg md initPeers
        -- If kademlia is enabled here then we'll try to read the configuration
        -- file. However it's not necessary that the file exists. If it doesn't,
        -- we can fill in some sensible defaults using the static routing and
        -- kademlia flags for other nodes.
        topologyOptKademlia <- if nmKademlia
            then do
                ekparams <- liftIO $ getKademliaParamsFromFile cfg
                case ekparams of
                    Right kparams -> return $ Just kparams
                    Left MissingKademliaConfig ->
                        let ekparams' = getKademliaParamsFromStatic kademliaPeers
                        in  either (throw . CannotParseKademliaConfig . Left) (return . Just) ekparams'
                    Left err -> throw err
            else return Nothing
        case nmType of
          T.NodeCore  -> return $ T.TopologyCore{..}
          T.NodeRelay -> return $ T.TopologyRelay{topologyMaxSubscrs = nmMaxSubscrs, ..}
          T.NodeEdge  -> throw NetworkConfigSelfEdge
      Y.TopologyBehindNAT{..} ->
        return T.TopologyBehindNAT{..}
      Y.TopologyP2P{..} -> do
        kparams <- either throw return =<< liftIO (getKademliaParamsFromFile cfg)
        return T.TopologyP2P{topologyKademlia = kparams, ..}
      Y.TopologyTraditional{..} -> do
        kparams <- either throw return =<< liftIO (getKademliaParamsFromFile cfg)
        return T.TopologyTraditional{topologyKademlia = kparams, ..}

    (enqueuePolicy, dequeuePolicy, failurePolicy) <- case networkConfigOptsPolicies of
        -- If no policy file is given we just use the default derived from the
        -- topology.
        Nothing -> return
            ( T.topologyEnqueuePolicy ourTopology
            , T.topologyDequeuePolicy ourTopology
            , T.topologyFailurePolicy ourTopology
            )
        -- A policy file is given: the topology-derived defaults are ignored
        -- and we take the complete policy description from the file.
        Just fp -> liftIO $ Y.fromStaticPolicies <$> readPolicies fp

    return T.NetworkConfig {
        ncTopology      = ourTopology
      , ncDefaultPort   = networkConfigOptsPort
      , ncSelfName      = networkConfigOptsSelf
      , ncEnqueuePolicy = enqueuePolicy
      , ncDequeuePolicy = dequeuePolicy
      , ncFailurePolicy = failurePolicy
      }

-- | Come up with kademlia parameters, possibly giving 'Left' in case
-- there's no configuration file path given, or if it couldn't be parsed.
getKademliaParamsFromFile :: NetworkConfigOpts
                          -> IO (Either NetworkConfigException DHT.KademliaParams)
getKademliaParamsFromFile cfg = case networkConfigOptsKademlia cfg of
    Nothing -> return $ Left MissingKademliaConfig
    Just fp -> do
      kconf <- parseKademlia fp
      either (return . Left . CannotParseKademliaConfig . Left . DHT.MalformedDHTKey)
             (return . Right)
             (DHT.fromYamlConfig kconf)

-- | Derive kademlia parameters from the set of kademlia-enabled peers. They
-- are used as the initial peers, and everything else is unspecified, and will
-- be defaulted.
getKademliaParamsFromStatic :: [Y.KademliaAddress]
                            -> Either DHT.MalformedDHTKey DHT.KademliaParams
-- Since 'Nothing' is given for the kpId, it's impossible to get a 'Left'
getKademliaParamsFromStatic kpeers = either (Left . DHT.MalformedDHTKey) Right kparams
  where
    kparams = DHT.fromYamlConfig $ Y.KademliaParams
        { Y.kpId              = Nothing
        , Y.kpPeers           = kpeers
        , Y.kpAddress         = Nothing
        , Y.kpBind            = Nothing
        , Y.kpExplicitInitial = Nothing
        , Y.kpDumpFile        = Nothing
        }

-- | Perspective on 'AllStaticallyKnownPeers' from the point of view of
-- a single node.
--
-- First component is this node's metadata.
-- Second component is the set of all known peers (routes included).
-- Third component is the set of addresses of peers running kademlia.
--   If this node runs kademlia, its address will appear as the last entry in
--   the list.
fromPovOf :: NetworkConfigOpts
          -> Y.AllStaticallyKnownPeers
          -> IO (NodeMetadata, Peers NodeId, [Y.KademliaAddress])
fromPovOf cfg@NetworkConfigOpts{..} allPeers =
    case networkConfigOptsSelf of
      Nothing   -> throwM NetworkConfigSelfUnknown
      Just self -> T.initDnsOnUse $ \resolve -> do
        selfMetadata <- metadataFor allPeers self
        resolved     <- resolvePeers resolve (Y.allStaticallyKnownPeers allPeers)
        routes       <- mkRoutes (second addressToNodeId <$> resolved) (Y.nmRoutes selfMetadata)
        let directory     = M.fromList (map (\(a, b) -> (addressToNodeId b, a)) (M.elems resolved))
            hasKademlia   = M.filter nmKademlia (Y.allStaticallyKnownPeers allPeers)
            selfKademlia  = M.member self hasKademlia
            otherKademlia = M.delete self hasKademlia
            -- Linter claims that
            --   [self | selfKademlia]
            -- is more readable than
            --   if selfKademlia then [self] else []
            allKademlia   = M.keys otherKademlia ++ [self | selfKademlia]

            kademliaPeers = mkKademliaAddress . snd <$> mapMaybe (\name -> M.lookup name resolved) allKademlia
        return (selfMetadata, peersFromList directory routes, kademliaPeers)
  where

    mkKademliaAddress :: NetworkAddress -> Y.KademliaAddress
    mkKademliaAddress (addr, port) = Y.KademliaAddress
        { Y.kaHost = BS.C8.unpack addr
        , Y.kaPort = port
        }

    -- Use the name/metadata association to come up with types and
    -- addresses for each name.
    resolvePeers :: T.Resolver -> Map NodeName Y.NodeMetadata -> IO (Map NodeName (T.NodeType, NetworkAddress))
    resolvePeers resolve = M.traverseWithKey (resolvePeer resolve)

    resolvePeer :: T.Resolver -> NodeName -> Y.NodeMetadata -> IO (T.NodeType, NetworkAddress)
    resolvePeer resolve name metadata =
      (typ,) <$> resolveNodeAddr cfg resolve (name, addr)
      where
        typ  = nmType metadata
        addr = nmAddress metadata

    -- Given a NodeName directory (see 'resolvePeers'), fill in the NodeRoutes
    -- by looking up the relevant names.
    -- It's assumed that each name in a list of alternatives has the same
    -- type.
    mkRoutes :: Map NodeName (T.NodeType, NodeId) -> Y.NodeRoutes -> IO [(T.NodeType, Alts NodeId)]
    mkRoutes directory (Y.NodeRoutes routes) = mapM (mkAlts directory) routes

    mkAlts :: Map NodeName (T.NodeType, NodeId) -> Alts NodeName -> IO (T.NodeType, Alts NodeId)
    mkAlts _ [] = throwM $ EmptyListOfAltsFor (fromJust networkConfigOptsSelf)
    mkAlts directory names@(name:_) = do
      -- Use the type associated to the first name, and assume all alts have
      -- same type.
      -- TODO we could easily check that using
      --
      --   mapM (resolveName directory) names :: IO (NodeType, NodeId)
      --
      -- and throw an exception if there's a mismatch.
      typ  <- fmap fst . resolveName directory $ name
      nids <- mapM (fmap snd . resolveName directory) names
      return (typ, nids)

    resolveName :: Map NodeName t -> NodeName -> IO t
    resolveName directory name = case M.lookup name directory of
      Nothing -> throwM $ UndefinedNodeName name
      Just t  -> return t

-- | Resolve node name to IP address
--
-- We do this when reading the topology file so that we detect DNS problems
-- early, and so that we are using canonical addresses (IP addresses) for
-- node IDs.
--
-- NOTE: This is /only/ used for core or edge nodes (nodes with a statically
-- configured set of peers). For such nodes it makes sense to detect DNS
-- problems at startup. For behind NAT nodes we do not do any resolution at
-- this point; instead, it happens dynamically in the subscription worker.
-- This is important; in user applications we certainly don't want to prevent
-- the application from starting up because of DNS problems at startup.
--
-- TODO: Support re-reading this file after SIGHUP.
resolveNodeAddr :: NetworkConfigOpts
                -> T.Resolver
                -> (NodeName, NodeAddr (Maybe DNS.Domain))
                -> IO NetworkAddress
resolveNodeAddr cfg _ (_, NodeAddrExact addr mPort) = do
    let port = fromMaybe (networkConfigOptsPort cfg) mPort
    return (encodeUtf8 @String . show $ addr, port)
resolveNodeAddr cfg resolve (name, NodeAddrDNS mHost mPort) = do
    let host = fromMaybe (nameToDomain name)         mHost
        port = fromMaybe (networkConfigOptsPort cfg) mPort

    mAddrs <- resolve host
    case mAddrs of
      Left err            -> throwM $ NetworkConfigDnsError host err
      Right []            -> throwM $ CannotResolve name
      Right addrs@(_:_:_) -> throwM $ NoUniqueResolution name addrs
      Right [addr]        -> return $ ipv4ToNetworkAddress addr port
  where
    nameToDomain :: NodeName -> DNS.Domain
    nameToDomain (NodeName n) = BS.C8.pack (toString n)

ipv4ToNetworkAddress :: IPv4 -> Word16 -> NetworkAddress
ipv4ToNetworkAddress addr port = (BS.C8.pack (show addr), port)

metadataFor :: Y.AllStaticallyKnownPeers -> NodeName -> IO Y.NodeMetadata
metadataFor (Y.AllStaticallyKnownPeers allPeers) node =
    case M.lookup node allPeers of
      Nothing       -> throwM $ UndefinedNodeName node
      Just metadata -> return metadata

readTopology :: FilePath -> IO Y.Topology
readTopology fp = do
    mTopology <- Yaml.decodeFileEither fp
    case mTopology of
      Left  err      -> throwM $ CannotParseNetworkConfig err
      Right topology -> return topology

readPolicies :: FilePath -> IO Y.StaticPolicies
readPolicies fp = do
    mStaticPolicies <- Yaml.decodeFileEither fp
    case mStaticPolicies of
      Left  err            -> throwM $ CannotParsePolicies err
      Right staticPolicies -> return staticPolicies

parseKademlia :: FilePath -> IO Y.KademliaParams
parseKademlia fp = do
    mKademlia <- Yaml.decodeFileEither fp
    case mKademlia of
      Left  err      -> throwM $ CannotParseKademliaConfig (Right err)
      Right kademlia -> return kademlia

{-------------------------------------------------------------------------------
  Errors
-------------------------------------------------------------------------------}

-- | Something is wrong with the network configuration
--
-- NOTE: Behind NAT nodes are not given an explicit network configuration file,
-- but instead rely on the default topology. These exceptions should never be
-- thrown for behind NAT nodes, as we don't want to prevent the user application
-- from starting up.
data NetworkConfigException =
    -- | We cannot parse the topology .yaml file
    CannotParseNetworkConfig Yaml.ParseException

    -- | A Kademlia configuration file is expected but was not specified.
  | MissingKademliaConfig

    -- | We cannot parse the kademlia .yaml file
  | CannotParseKademliaConfig (Either DHT.MalformedDHTKey Yaml.ParseException)

    -- | A policy description .yaml was specified but couldn't be parsed.
  | CannotParsePolicies Yaml.ParseException

    -- | We use a set of statically known peers but we weren't given the
    -- name of the current node
  | NetworkConfigSelfUnknown

    -- | We resolved our name under static configuration to be an edge node.
    -- This indicates a programmer error.
  | NetworkConfigSelfEdge

    -- | The .yaml file contains a node name which is undefined
  | UndefinedNodeName NodeName

    -- | The static routes for a node contains an empty list of alternatives
  | EmptyListOfAltsFor NodeName

    -- | Something went wrong during node name resolution
  | NetworkConfigDnsError DNS.Domain DNS.DNSError

    -- | Could not resolve a node name to an IP address
  | CannotResolve NodeName

    -- | DNS returned multiple IP addresses for the give node name
    --
    -- This is no good because we need canonical node IDs.
  | NoUniqueResolution NodeName [IPv4]
  deriving (Show)

instance Exception NetworkConfigException
