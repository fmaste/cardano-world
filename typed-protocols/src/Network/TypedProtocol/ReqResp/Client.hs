{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}

module Network.TypedProtocol.ReqResp.Client where

import           Network.TypedProtocol.Core
import           Network.TypedProtocol.Pipelined
import           Network.TypedProtocol.ReqResp.Type

data ReqRespClient req resp m a where
  SendMsgReq     :: req
                 -> (resp -> m (ReqRespClient req resp m a))
                 -> ReqRespClient req resp m a

  SendMsgDone    :: a -> ReqRespClient req resp m a


-- | Interpret a particular client action sequence into the client side of the
-- 'ReqResp' protocol.
--
reqRespClientPeer
  :: Monad m
  => ReqRespClient req resp m a
  -> Peer (ReqResp req resp) AsClient StIdle m a

reqRespClientPeer (SendMsgDone result) =
    -- We do an actual transition using 'yield', to go from the 'StIdle' to
    -- 'StDone' state. Once in the 'StDone' state we can actually stop using
    -- 'done', with a return value.
    Yield (ClientAgency TokIdle) MsgDone (Done TokDone result)

reqRespClientPeer (SendMsgReq req next) =

    -- Send our message.
    Yield (ClientAgency TokIdle) (MsgReq req) $

    -- The type of our protocol means that we're now into the 'StBusy' state
    -- and the only thing we can do next is local effects or wait for a reply.
    -- We'll wait for a reply.
    Await (ServerAgency TokBusy) $ \(MsgResp resp) ->

    -- Now in this case there is only one possible response, and we have
    -- one corresponding continuation 'kPong' to handle that response.
    -- The pong reply has no content so there's nothing to pass to our
    -- continuation, but if there were we would.
      Effect $ do
        client <- next resp
        pure $ reqRespClientPeer client


-- | A request-response client designed for running the 'ReqResp' protocol in
-- a pipelined way.
--
data ReqRespSender req resp m a where
  -- | Send a `Req` message but alike in `ReqRespClient` do not await for the
  -- resopnse, instead supply a monadic action which will run on a received
  -- `Pong` message.
  SendMsgReqPipelined
    :: req
    -> (resp -> m ())    -- receive action
    -> ReqRespSender req resp m a -- continuation
    -> ReqRespSender req resp m a

  -- | Termination of the req-resp protocol.
  SendMsgDonePipelined
    :: a -> ReqRespSender req resp m a


reqRespClientPeerSender
  :: Monad m
  => ReqRespSender req resp m a
  -> PeerSender (ReqResp req resp) AsClient StIdle m a

reqRespClientPeerSender (SendMsgDonePipelined result) =
  -- Send `MsgDone` and complete the protocol
  SenderYield
    (ClientAgency TokIdle)
    MsgDone
    ReceiverDone
    (SenderDone TokDone result)

reqRespClientPeerSender (SendMsgReqPipelined req receive next) =
  -- Piplined yield: send `MsgReq`, imediatelly follow with the next step.
  -- Await for a response in a continuation.
  SenderYield
    (ClientAgency TokIdle)
    (MsgReq req)
    -- response handler
    (ReceiverAwait (ServerAgency TokBusy) $ \(MsgResp resp) ->
        ReceiverEffect $ do
          receive resp
          return ReceiverDone)
    -- run the next step of the req-resp protocol.
    (reqRespClientPeerSender next)

