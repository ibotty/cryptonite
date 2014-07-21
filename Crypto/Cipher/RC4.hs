{-# LANGUAGE ForeignFunctionInterface, CPP #-}
-- |
-- Module      : Crypto.Cipher.RC4
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : stable
-- Portability : Good
--
-- Simple implementation of the RC4 stream cipher.
-- http://en.wikipedia.org/wiki/RC4
--
-- Initial FFI implementation by Peter White <peter@janrain.com>
--
-- Reorganized and simplified to have an opaque context.
--
module Crypto.Cipher.RC4
    ( initialize
    , combine
    , generate
    , State
    ) where

import Data.Word
import Data.Byteable
import Foreign.Ptr
import Foreign.ForeignPtr
import System.IO.Unsafe
import Data.Byteable
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import Control.Applicative ((<$>))

----------------------------------------------------------------------
unsafeDoIO :: IO a -> a
#if __GLASGOW_HASKELL__ > 704
unsafeDoIO = unsafeDupablePerformIO
#else
unsafeDoIO = unsafePerformIO
#endif

-- | The encryption state for RC4
newtype State = State ByteString

-- | C Call for initializing the encryptor
foreign import ccall unsafe "cryptonite_rc4.h cryptonite_rc4_init"
    c_rc4_init :: Ptr Word8 -- ^ The rc4 key
               -> Word32    -- ^ The key length
               -> Ptr State   -- ^ The context
               -> IO ()

foreign import ccall unsafe "cryptonite_rc4.h cryptonite_rc4_combine"
    c_rc4_combine :: Ptr State        -- ^ Pointer to the permutation
                  -> Ptr Word8      -- ^ Pointer to the clear text
                  -> Word32         -- ^ Length of the clear text
                  -> Ptr Word8      -- ^ Output buffer
                  -> IO ()

withByteStringPtr :: ByteString -> (Ptr Word8 -> IO a) -> IO a
withByteStringPtr b f = withForeignPtr fptr $ \ptr -> f (ptr `plusPtr` off)
    where (fptr, off, _) = B.toForeignPtr b

-- | RC4 context initialization.
--
-- seed the context with an initial key. the key size need to be
-- adequate otherwise security takes a hit.
initialize :: Byteable key
           => key   -- ^ The key
           -> State -- ^ The RC4 context with the key mixed in
initialize key = unsafeDoIO $ do
    State <$> (B.create 264 $ \ctx -> withBytePtr key $ \keyPtr -> c_rc4_init (castPtr keyPtr) (fromIntegral $ byteableLength key) (castPtr ctx))

-- | generate the next len bytes of the rc4 stream without combining
-- it to anything.
generate :: State -> Int -> (State, ByteString)
generate ctx len = combine ctx (B.replicate len 0)

-- | RC4 xor combination of the rc4 stream with an input
combine :: State               -- ^ rc4 context
        -> ByteString          -- ^ input
        -> (State, ByteString) -- ^ new rc4 context, and the output
combine (State cctx) clearText = unsafeDoIO $
    B.mallocByteString 264 >>= \dctx ->
    B.mallocByteString len >>= \outfptr ->
    withByteStringPtr clearText $ \clearPtr ->
    withByteStringPtr cctx $ \srcState ->
    withForeignPtr dctx $ \dstState -> do
    withForeignPtr outfptr $ \outptr -> do
        B.memcpy dstState srcState 264
        c_rc4_combine (castPtr dstState) clearPtr (fromIntegral len) outptr
        return $! (State $! B.PS dctx 0 264, B.PS outfptr 0 len)
    where len = B.length clearText