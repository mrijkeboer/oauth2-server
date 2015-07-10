--
-- Copyright © 2013-2015 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

-- This should be removed when the 'HasLink (Headers ...)' instance is removed.
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Description: OAuth2 API implementation.
--
-- OAuth2 API implementation.
--
-- This implementation assumes the use of Shibboleth, which doesn't actually
-- mean anything all that specific. This just means that we expect a particular
-- header that says who the user is and what permissions they have to delegate.
--
-- The intention is to seperate all OAuth2 specific logic from our particular
-- way of handling AAA.
module Network.OAuth2.Server.API (
    -- * HTTP Headers
    NoStore,
    NoCache,
    OAuthUserHeader,
    OAuthUserScopeHeader,

    -- * API types
    --
    -- $ These types describe the OAuth2 Server HTTP API.

    OAuth2API,
    TokenEndpoint,
    AuthorizeEndpoint,
    AuthorizePost,
    VerifyEndpoint,

    -- * API handlers
    --
    -- $ These functions each handle a single endpoint in the OAuth2 Server
    -- HTTP API.

    oAuth2API,
    oAuth2APIserver,
    tokenEndpoint,
    authorizeEndpoint,
    processAuthorizeGet,
    authorizePost,
    verifyEndpoint,

    -- * Helpers

    checkClientAuth,
    processTokenRequest,
    throwOAuth2Error,
    handleShib,
) where

import           Control.Concurrent.STM      (TChan, atomically, writeTChan)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Error.Class   (MonadError (throwError))
import           Control.Monad.IO.Class      (MonadIO (liftIO))
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Except  (ExceptT, runExceptT)
import           Crypto.Scrypt
import           Data.Aeson                  (encode)
import           Data.ByteString.Conversion  (ToByteString (..))
import           Data.Foldable               (traverse_)
import           Data.Maybe
import           Data.Monoid
import           Data.Proxy
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T
import           Data.Time.Clock             (UTCTime, addUTCTime,
                                              getCurrentTime)
import           Formatting                  (sformat, shown, (%))
import           Network.HTTP.Types          hiding (Header)
import           Network.OAuth2.Server.Types as X
import           Servant.API                 ((:<|>) (..), (:>),
                                              AddHeader (addHeader),
                                              FormUrlEncoded, Get, Header,
                                              Headers, JSON, OctetStream,
                                              Post, QueryParam, ReqBody,
                                              ToFormUrlEncoded (..))
import           Servant.HTML.Blaze
import           Servant.Server              (ServantErr (errBody, errHeaders),
                                              Server, err302, err400, err401,
                                              err404)
import           Servant.Utils.Links
import           System.Log.Logger
import           Text.Blaze.Html5            (Html)

import           Network.OAuth2.Server.Store hiding (logName)
import           Network.OAuth2.Server.UI

-- Logging

logName :: String
logName = "Network.OAuth2.Server.API"

-- Wrappers for underlying logging system
debugLog, errorLog :: MonadIO m => String -> Text -> m ()
debugLog = wrapLogger debugM
errorLog = wrapLogger errorM

wrapLogger :: MonadIO m => (String -> String -> IO a) -> String -> Text -> m a
wrapLogger logger component msg = do
    liftIO $ logger (logName <> " " <> component <> ": ") (T.unpack msg)

-- * HTTP Headers
--
-- $ The OAuth2 Server API uses HTTP headers to exchange information between
-- system components and to control caching behaviour.

-- TODO: Move this into some servant common package

-- | HTTP implementations should not store this request.
--
--   http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.9.2
--
--   The purpose of the no-store directive is to prevent the inadvertent
--   release retention of sensitive information (for example, on backup tapes).

data NoStore = NoStore
instance ToByteString NoStore where
    builder _ = "no-store"

-- | HTTP implementations should not cache this request.
--
--   http://tools.ietf.org/html/rfc2616#section-14.32
--
--   We use this in Pragma headers, for compatibilty.
data NoCache = NoCache
instance ToByteString NoCache where
    builder _ = "no-cache"

-- | Temporary instance to create links with headers pending
--   servant 0.4.3/0.5
--
--   When this is removed, also delete the -fno-warn-orphans option above.
instance HasLink sub => HasLink (Header sym a :> sub) where
    type MkLink (Header sym a :> sub) = MkLink sub
    toLink _ = toLink (Proxy :: Proxy sub)

-- | Shibboleth will pass us the UID of the authenticated user in this header.
type OAuthUserHeader = "Identity-OAuthUser"

-- | Shibboleth will pass us the available permissions of the authenticated
--   user in this header.
type OAuthUserScopeHeader = "Identity-OAuthUserScopes"

-- | Type-list of headers to disable HTTP caching in clients.
--
--   This is used in several places throughout the API and, furthermore, breaks
--   haskell-src-exts, hlint, etc. when used inline in more complex types.
type CachingHeaders = '[HdrCacheControl, HdrPragma]

-- | 'Header' type for the Cache-Control HTTP header.
--
--   Used in 'CachingHeaders'.
type HdrCacheControl = Header "Cache-Control" NoStore

-- | 'Header' type for the Pragma HTTP header.
--
--   Used in 'CachingHeaders'.
type HdrPragma = Header "Pragma" NoCache

-- | Request a token, basically AccessRequest -> AccessResponse with noise.
--
-- The response headers are mentioned here:
--
-- https://tools.ietf.org/html/rfc6749#section-5.1
--
--    The authorization server MUST include the HTTP "Cache-Control" response
--    header field [RFC2616] with a value of "no-store" in any response
--    containing tokens, credentials, or other sensitive information, as well
--    as the "Pragma" response header field [RFC2616] with a value of
--    "no-cache".
type TokenEndpoint
    = "token"
    :> Header "Authorization" AuthHeader
    :> ReqBody '[FormUrlEncoded] (Either OAuth2Error AccessRequest)
                                 -- The Either here is a weird hack to be able to handle parse failures explicitly.
    :> Post '[JSON] (Headers CachingHeaders AccessResponse)

-- | Encode an 'OAuth2Error' and throw it to servant.
--

-- TODO: Fix the name/behaviour. Terrible name for something that 400s.
throwOAuth2Error :: MonadError ServantErr m => OAuth2Error -> m a
throwOAuth2Error e =
    throwError err400 { errBody = encode e
                      , errHeaders = [("Content-Type", "application/json")]
                      }

-- | Handler for 'TokenEndpoint', basically a wrapper for 'processTokenRequest'
tokenEndpoint :: TokenStore ref => ref -> TChan GrantEvent -> Server TokenEndpoint
tokenEndpoint _ _ _ (Left e) = throwOAuth2Error e
tokenEndpoint ref sink auth (Right req) = do
    t <- liftIO getCurrentTime
    res <- liftIO . runExceptT $ processTokenRequest ref t auth req
    case res of
        Left e -> throwOAuth2Error e
        Right response -> do
            void . liftIO . atomically . writeTChan sink $ case req of
                RequestAuthorizationCode{} -> CodeGranted
                RequestClientCredentials{} -> ClientCredentialsGranted
                RequestRefreshToken{}      -> RefreshGranted
            return . addHeader NoStore . addHeader NoCache $ response

-- | Check that the request is valid. If it is we provide an 'AccessResponse',
-- otherwise we return an 'OAuth2Error'.
--
-- Any IO exceptions that are thrown are probably catastrophic and unaccounted
-- for, and should not be caught.
processTokenRequest
    :: forall m ref.
       (TokenStore ref, m ~ ExceptT OAuth2Error IO)
    => ref                                        -- ^ PG pool, ioref, etc.
    -> UTCTime                                    -- ^ Time of request
    -> Maybe AuthHeader                           -- ^ Who wants the token?
    -> AccessRequest                              -- ^ What do they want?
    -> ExceptT OAuth2Error IO AccessResponse
processTokenRequest _ _ Nothing _ = do
    errorLog "processTokenRequest" "Checking credentials but none provided."
    invalidRequest "No credentials provided"
processTokenRequest ref t (Just client_auth) req = do
    debugLog "checkCredentials" "Checking some credentials"
    c_id <- checkClientAuth ref client_auth
    client_id <- case c_id of
        Nothing -> unauthorizedClient "Invalid client credentials"
        Just client_id -> return client_id

    (user, modified_scope, maybe_token_id) <- case req of
        -- https://tools.ietf.org/html/rfc6749#section-4.1.3
        RequestAuthorizationCode auth_code uri client -> do
            (user, modified_scope) <- checkClientAuthCode client_id auth_code uri client
            return (user, modified_scope, Nothing)
        -- http://tools.ietf.org/html/rfc6749#section-4.4.2
        RequestClientCredentials _ ->
            unsupportedGrantType "client_credentials is not supported"
        -- http://tools.ietf.org/html/rfc6749#section-6
        RequestRefreshToken tok request_scope ->
            checkRefreshToken client_id tok request_scope

    let expires = Just $ addUTCTime 1800 t
        access_grant = TokenGrant
            { grantTokenType = Bearer
            , grantExpires = expires
            , grantUserID = user
            , grantClientID = Just client_id
            , grantScope = modified_scope
            }
        -- Create a refresh token with these details.
        refresh_expires = Just $ addUTCTime (3600 * 24 * 7) t
        refresh_grant = access_grant
            { grantTokenType = Refresh
            , grantExpires = refresh_expires
            }
    -- Save the new tokens to the store.
    (rid, refresh_details) <- liftIO $ storeCreateToken ref refresh_grant Nothing
    (  _, access_details)  <- liftIO $ storeCreateToken ref access_grant (Just rid)

    -- Revoke the token iff we got one
    liftIO $ traverse_ (storeRevokeToken ref) maybe_token_id

    return $ grantResponse t access_details (Just $ tokenDetailsToken refresh_details)
  where
    fromMaybeM :: m a -> m (Maybe a) -> m a
    fromMaybeM d x = x >>= maybe d return

    --
    -- Verify client, scope and request code.
    --
    checkClientAuthCode :: ClientID -> Code -> Maybe RedirectURI -> Maybe ClientID -> m (Maybe UserID, Scope)
    checkClientAuthCode _ _ _ Nothing = invalidRequest "No client ID supplied."
    checkClientAuthCode client_id auth_code uri (Just purported_client) = do
        when (client_id /= purported_client) $ unauthorizedClient "Invalid client credentials"
        request_code <- fromMaybeM (invalidGrant "Request code not found")
                                   (liftIO $ storeReadCode ref auth_code)
        -- Fail if redirect_uri doesn't match what's in the database.
        case uri of
            Just uri' | uri' /= (requestCodeRedirectURI request_code) -> do
                debugLog "checkClientAuthCode" $
                    sformat ("Redirect URI mismatch verifying access token request: requested"
                            % shown % " but got " % shown )
                            uri (requestCodeRedirectURI request_code)
                invalidRequest "Invalid redirect URI"
            _ -> return ()

        case requestCodeScope request_code of
            Nothing -> do
                debugLog "checkClientAuthCode" $
                    sformat ("No scope found for code " % shown) request_code
                invalidScope "No scope found"
            Just code_scope -> return (Just $ requestCodeUserID request_code, code_scope)

    --
    -- Verify scope and request token.
    --
    checkRefreshToken :: ClientID -> Token -> Maybe Scope -> m (Maybe UserID, Scope, Maybe TokenID)
    checkRefreshToken client_id tok request_scope = do
        previous <- liftIO $ storeReadToken ref (Left tok)
        case previous of
            Just (tid, TokenDetails{..})
                | (Just client_id == tokenDetailsClientID) -> do
                    let scope' = fromMaybe tokenDetailsScope request_scope
                    -- Check scope compatible.
                    -- @TODO(thsutton): The concern with scopes should probably
                    -- be completely removed here.
                    unless (compatibleScope scope' tokenDetailsScope) $ do
                        debugLog "checkRefreshToken" $
                            sformat ("Refresh requested with incompatible scopes"
                                    % shown % " vs " % shown)
                                    request_scope tokenDetailsScope
                        invalidScope "Incompatible scope"
                    return (tokenDetailsUserID, scope', Just tid)

            -- The old token is dead or client_id doesn't match.
            _ -> do
                debugLog "checkRefreshToken" $
                    sformat ("Got passed invalid token " % shown) tok
                invalidRequest "Invalid token"


-- | OAuth2 Authorization Endpoint
--
-- Allows authenticated users to review and authorize a code token grant
-- request.
--
-- http://tools.ietf.org/html/rfc6749#section-3.1
type AuthorizeEndpoint
    = "authorize"
    :> Header OAuthUserHeader UserID
    :> Header OAuthUserScopeHeader Scope
    :> QueryParam "response_type" ResponseType
    :> QueryParam "client_id" ClientID
    :> QueryParam "redirect_uri" RedirectURI
    :> QueryParam "scope" Scope
    :> QueryParam "state" ClientState
    :> Get '[HTML] Html

-- | OAuth2 Authorization Endpoint
--
-- Allows authenticated users to review and authorize a code token grant
-- request.
--
-- http://tools.ietf.org/html/rfc6749#section-3.1
type AuthorizePost
    = "authorize"
    :> Header OAuthUserHeader UserID
    :> Header OAuthUserScopeHeader Scope
    :> ReqBody '[FormUrlEncoded] AuthorizePostRequest
    :> Post '[HTML] ()

-- | Facilitates services checking tokens.
--
-- This endpoint allows an authorized client to verify that a token is valid
-- and retrieve information about the principal and token scope.
type VerifyEndpoint
    = "verify"
    :> Header "Authorization" AuthHeader
    :> ReqBody '[OctetStream] Token
    :> Post '[JSON] (Headers CachingHeaders AccessResponse)

-- | OAuth2 Server HTTP endpoints.
--
-- Includes endpoints defined in RFC6749 describing OAuth2, plus application
-- specific extensions.
type OAuth2API
       = TokenEndpoint
    :<|> VerifyEndpoint
    :<|> AuthorizeEndpoint
    :<|> AuthorizePost

-- | Servant API for OAuth2
oAuth2API :: Proxy OAuth2API
oAuth2API = Proxy

-- | Construct a server of the entire API from an initial state
oAuth2APIserver :: TokenStore ref => ref -> ServerOptions -> TChan GrantEvent -> Server OAuth2API
oAuth2APIserver ref serverOpts sink
       = tokenEndpoint ref sink
    :<|> verifyEndpoint ref serverOpts
    :<|> handleShib (authorizeEndpoint ref)
    :<|> handleShib (authorizePost ref)

-- | Any shibboleth authed endpoint must have all relevant headers defined, and
-- any other case is an internal error. handleShib consolidates checking these
-- headers.
handleShib
    :: (UserID -> Scope -> a)
    -> Maybe UserID
    -> Maybe Scope
    -> a
handleShib f (Just u) (Just s) = f u s
handleShib _ _        _        = error "Expected Shibboleth headers"

-- | Implements the OAuth2 authorize endpoint.
--
--   This handler must be protected by Shibboleth (or other mechanism in the
--   front-end proxy). It decodes the client request and presents a UI allowing
--   the user to approve or reject a grant request.
--
--   http://tools.ietf.org/html/rfc6749#section-3.1

--   TODO: Handle the validation of things more nicely here, preferably
--   shifting them out of here entirely.
authorizeEndpoint
    :: ( MonadIO m
       , MonadBaseControl IO m
       , MonadError ServantErr m
       , TokenStore ref
       )
    => ref
    -> UserID             -- ^ Authenticated user
    -> Scope              -- ^ Authenticated permissions
    -> Maybe ResponseType -- ^ Requested response type.
    -> Maybe ClientID     -- ^ Requesting Client ID.
    -> Maybe RedirectURI  -- ^ Requested redirect URI.
    -> Maybe Scope        -- ^ Requested scope.
    -> Maybe ClientState  -- ^ State from requesting client.
    -> m Html
authorizeEndpoint ref user_id permissions response_type client_id' redirect scope' state = do
    res <- runExceptT $ processAuthorizeGet ref user_id permissions response_type client_id' redirect scope' state
    case res of
        Left (Nothing, e) -> throwOAuth2Error e
        Left (Just redirect', e) -> do
            let url = addQueryParameters redirect' $
                    over (mapped . both) T.encodeUtf8 (toFormUrlEncoded e) <>
                    [("state", state' ^.re clientState) | Just state' <- [state]]
            throwError err302{ errHeaders = [(hLocation, url ^.re redirectURI)] }
        Right x -> return x

-- | Process a GET request for the authorize endpoint.
processAuthorizeGet
    :: ( MonadIO m
       , MonadBaseControl IO m
       , MonadError (Maybe RedirectURI, OAuth2Error) m
       , TokenStore ref
       )
    => ref
    -> UserID             -- ^ Authenticated user
    -> Scope              -- ^ Authenticated permissions
    -> Maybe ResponseType -- ^ Requested response type.
    -> Maybe ClientID     -- ^ Requesting Client ID.
    -> Maybe RedirectURI  -- ^ Requested redirect URI.
    -> Maybe Scope        -- ^ Requested scope.
    -> Maybe ClientState  -- ^ State from requesting client.
    -> m Html
processAuthorizeGet ref user_id permissions response_type client_id' redirect scope' state = do
    -- Required: a ClientID value, which identifies a client.
    client_details@ClientDetails{..} <- case client_id' of
        Just client_id -> do
            client <- liftIO $ storeLookupClient ref client_id
            case client of
                Nothing -> error $ "Could not find client with id: " <> show client_id
                Just c -> return c
        Nothing -> error "ClientID is missing"

    -- Optional: requested redirect URI.
    -- https://tools.ietf.org/html/rfc6749#section-3.1.2.3
    redirect_uri <- case redirect of
        Nothing -> case clientRedirectURI of
            redirect':_ -> return redirect'
            _ -> error $ "No redirect_uri provided and no unique default registered for client " <> show clientClientId
        Just redirect'
            | redirect' `elem` clientRedirectURI -> return redirect'
            | otherwise -> error $ show redirect' <> " /= " <> show clientRedirectURI

    -- Required: a supported ResponseType value.
    case response_type of
        Just ResponseTypeCode -> return ()
        Just _  -> throwInvalidRequest redirect_uri "Invalid response type"
        Nothing -> throwInvalidRequest redirect_uri "Response type is missing"

    -- Optional (but we currently require): requested scope.
    requested_scope <- case scope' of
        Nothing -> throwInvalidRequest redirect_uri "Scope is missing"
        Just requested_scope
            | requested_scope `compatibleScope` permissions -> return requested_scope
            | otherwise -> throwInvalidScope redirect_uri

    -- Create a code for this request.
    request_code <- liftIO $ storeCreateCode ref user_id clientClientId redirect_uri requested_scope state

    return $ renderAuthorizePage request_code client_details
  where
    throwInvalidRequest redirect_uri errDesc =
        throwError ( Just redirect_uri
                   , OAuth2Error InvalidRequest
                                 (preview errorDescription errDesc)
                                 Nothing
                   )
    throwInvalidScope redirect_uri =
        throwError ( Just redirect_uri
                   , OAuth2Error InvalidScope
                                 (preview errorDescription "Invalid scope")
                                 Nothing
                   )

-- | Handle the approval or rejection, we get here from the page served in
-- 'authorizeEndpoint'
authorizePost
    :: ( MonadIO m
       , MonadBaseControl IO m
       , MonadError ServantErr m
       , TokenStore ref
       )
    => ref
    -> UserID
    -> Scope
    -> AuthorizePostRequest
    -> m ()
authorizePost ref user_id _scope (AuthorizeApproved code') = do
    res <- liftIO $ storeActivateCode ref code' user_id
    case res of
        Nothing -> throwError err401{ errBody = "You are not authorized to approve this request." }
        Just RequestCode{..} -> do
            let uri' = addQueryParameters requestCodeRedirectURI [("code", code' ^.re code)]
            throwError err302{ errHeaders = [(hLocation, uri' ^.re redirectURI)] }
authorizePost ref user_id _scope (AuthorizeDeclined code') = do
    res <- liftIO $ storeReadCode ref code'
    case res of
        Just RequestCode{..} | user_id == requestCodeUserID-> do
            void . liftIO $ storeDeleteCode ref code'
            let e = OAuth2Error AccessDenied Nothing Nothing
                url = addQueryParameters requestCodeRedirectURI $
                    over (mapped . both) T.encodeUtf8 (toFormUrlEncoded e) <>
                    [("state", state' ^.re clientState) | Just state' <- [requestCodeState]]
            throwError err302{ errHeaders = [(hLocation, url ^.re redirectURI)] }
        _ -> throwError err401{ errBody = "You are not authorized to approve this request." }

-- | Verify a token and return information about the principal and grant.
--
--   Restricted to authorized clients.
verifyEndpoint
    :: ( MonadIO m
       , MonadBaseControl IO m
       , MonadError ServantErr m
       , TokenStore ref
       )
    => ref
    -> ServerOptions
    -> Maybe AuthHeader
    -> Token
    -> m (Headers CachingHeaders AccessResponse)
verifyEndpoint _ ServerOptions{..} Nothing _token =
    throwError login
  where
    login = err401 { errHeaders = toHeaders $ BasicAuth (Realm optVerifyRealm)
                   , errBody = "Login to validate a token."
                   }
verifyEndpoint ref ServerOptions{..} (Just auth) token' = do
    -- 1. Check client authentication.
    client_id' <- liftIO . runExceptT $ checkClientAuth ref auth
    client_id <- case client_id' of
        Left e -> do
            errorLog "verifyEndpoint" $
                sformat ("Error verifying token: " % shown) (e :: OAuth2Error)
            throwError login
        Right Nothing -> do
            debugLog "verifyEndpoint" $
                sformat ("Invalid client credentials: " % shown) auth
            throwError login
        Right (Just cid) -> do
            return cid
    -- 2. Load token information.
    tok <- liftIO $ storeReadToken ref (Left token')
    case tok of
        Nothing -> do
            debugLog "verifyEndpoint" $
                sformat ("Cannot verify token: failed to lookup " % shown) token'
            throwError denied
        Just (_, details) -> do
            -- 3. Check client authorization.
            when (Just client_id /= tokenDetailsClientID details) $ do
                debugLog "verifyEndpoint" $
                    sformat ("Client " % shown %
                             " attempted to verify someone elses token: " % shown)
                            client_id token'
                throwError denied
            -- 4. Send the access response.
            now <- liftIO getCurrentTime
            return . addHeader NoStore . addHeader NoCache $ grantResponse now details (Just token')
  where
    denied = err404 { errBody = "This is not a valid token." }
    login = err401 { errHeaders = toHeaders $ BasicAuth (Realm optVerifyRealm)
                   , errBody = "Login to validate a token."
                   }

-- | Given an AuthHeader sent by a client, verify that it authenticates.
--   If it does, return the authenticated ClientID; otherwise, Nothing.
checkClientAuth
    :: (MonadIO m, MonadError OAuth2Error m, TokenStore ref)
    => ref
    -> AuthHeader
    -> m (Maybe ClientID)
checkClientAuth ref auth = do
    case preview authDetails auth of
        Nothing -> do
            debugLog "checkClientAuth" "Got an invalid auth header."
            invalidRequest "Invalid auth header provided."
        Just (client_id, secret) -> do
            client <- liftIO $ storeLookupClient ref client_id
            case client of
                Just ClientDetails{..} -> return $ verifyClientSecret client_id secret clientSecret
                Nothing -> do
                    debugLog "checkClientAuth" $
                        sformat ("Got a request for invalid client_id " % shown)
                                client_id
                    invalidClient "No such client."
  where
    verifyClientSecret client_id secret hash =
        let pass = Pass . T.encodeUtf8 $ review password secret in
        -- Verify with default scrypt params.
        if verifyPass' pass hash then Just client_id else Nothing
