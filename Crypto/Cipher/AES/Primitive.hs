{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Module      : Crypto.Cipher.AES.Primitive
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : stable
-- Portability : good
--
module Crypto.Cipher.AES.Primitive
    (
    -- * block cipher data types
      AES

    -- * Authenticated encryption block cipher types
    , AESGCM
    , AESOCB

    -- * creation
    , initAES

    -- * misc
    , genCTR
    , genCounter

    -- * encryption
    , encryptECB
    , encryptCBC
    , encryptCTR
    , encryptXTS
    , encryptGCM
    , encryptOCB

    -- * decryption
    , decryptECB
    , decryptCBC
    , decryptCTR
    , decryptXTS
    , decryptGCM
    , decryptOCB

    -- * incremental GCM
    , gcmMode
    , gcmInit
    , gcmAppendAAD
    , gcmAppendEncrypt
    , gcmAppendDecrypt
    , gcmFinish

    -- * incremental OCB
    , ocbMode
    , ocbInit
    , ocbAppendAAD
    , ocbAppendEncrypt
    , ocbAppendDecrypt
    , ocbFinish
    ) where

import           Data.Word
import           Foreign.Ptr
import           Foreign.C.Types
import           Foreign.C.String

import           Crypto.Error
import           Crypto.Cipher.Types
import           Crypto.Cipher.Types.Block (IV(..))
import           Crypto.Internal.Compat
import           Crypto.Internal.Imports
import           Crypto.Internal.ByteArray (ByteArray, ByteArrayAccess, ScrubbedBytes, withByteArray)
import qualified Crypto.Internal.ByteArray as B

instance Cipher AES where
    cipherName    _ = "AES"
    cipherKeySize _ = KeySizeEnum [16,24,32]
    cipherInit k    = initAES k

instance BlockCipher AES where
    blockSize _ = 16
    ecbEncrypt = encryptECB
    ecbDecrypt = decryptECB
    cbcEncrypt = encryptCBC
    cbcDecrypt = decryptCBC
    ctrCombine = encryptCTR
    aeadInit AEAD_GCM aes iv = CryptoPassed $ AEAD (gcmMode aes) (gcmInit aes iv)
    aeadInit AEAD_OCB aes iv = CryptoPassed $ AEAD (ocbMode aes) (ocbInit aes iv)
    aeadInit _        _   _  = CryptoFailed CryptoError_AEADModeNotSupported
instance BlockCipher128 AES where 
    xtsEncrypt = encryptXTS
    xtsDecrypt = decryptXTS

-- | Create an AES AEAD implementation for GCM
gcmMode :: AES -> AEADModeImpl AESGCM
gcmMode aes = AEADModeImpl
    { aeadImplAppendHeader = gcmAppendAAD
    , aeadImplEncrypt      = gcmAppendEncrypt aes
    , aeadImplDecrypt      = gcmAppendDecrypt aes
    , aeadImplFinalize     = gcmFinish aes
    }

-- | Create an AES AEAD implementation for OCB
ocbMode :: AES -> AEADModeImpl AESOCB
ocbMode aes = AEADModeImpl
    { aeadImplAppendHeader = ocbAppendAAD aes
    , aeadImplEncrypt      = ocbAppendEncrypt aes
    , aeadImplDecrypt      = ocbAppendDecrypt aes
    , aeadImplFinalize     = ocbFinish aes
    }


-- | AES Context (pre-processed key)
newtype AES = AES ScrubbedBytes
    deriving (NFData)

-- | AESGCM State
newtype AESGCM = AESGCM ScrubbedBytes
    deriving (NFData)

-- | AESOCB State
newtype AESOCB = AESOCB ScrubbedBytes
    deriving (NFData)

sizeGCM :: Int
sizeGCM = 80

sizeOCB :: Int
sizeOCB = 160

keyToPtr :: AES -> (Ptr AES -> IO a) -> IO a
keyToPtr (AES b) f = withByteArray b (f . castPtr)

ivToPtr :: ByteArrayAccess iv => iv -> (Ptr Word8 -> IO a) -> IO a
ivToPtr iv f = withByteArray iv (f . castPtr)


ivCopyPtr :: IV AES -> (Ptr Word8 -> IO a) -> IO (a, IV AES)
ivCopyPtr (IV iv) f = (\(x,y) -> (x, IV y)) `fmap` copyAndModify iv f
  where
    copyAndModify :: ByteArray ba => ba -> (Ptr Word8 -> IO a) -> IO (a, ba)
    copyAndModify ba f' = B.copyRet ba f'

withKeyAndIV :: ByteArrayAccess iv => AES -> iv -> (Ptr AES -> Ptr Word8 -> IO a) -> IO a
withKeyAndIV ctx iv f = keyToPtr ctx $ \kptr -> ivToPtr iv $ \ivp -> f kptr ivp

withKey2AndIV :: ByteArrayAccess iv => AES -> AES -> iv -> (Ptr AES -> Ptr AES -> Ptr Word8 -> IO a) -> IO a
withKey2AndIV key1 key2 iv f =
    keyToPtr key1 $ \kptr1 -> keyToPtr key2 $ \kptr2 -> ivToPtr iv $ \ivp -> f kptr1 kptr2 ivp

withGCMKeyAndCopySt :: AES -> AESGCM -> (Ptr AESGCM -> Ptr AES -> IO a) -> IO (a, AESGCM)
withGCMKeyAndCopySt aes (AESGCM gcmSt) f =
    keyToPtr aes $ \aesPtr -> do
        newSt <- B.copy gcmSt (\_ -> return ())
        a     <- withByteArray newSt $ \gcmStPtr -> f (castPtr gcmStPtr) aesPtr
        return (a, AESGCM newSt)

withNewGCMSt :: AESGCM -> (Ptr AESGCM -> IO ()) -> IO AESGCM
withNewGCMSt (AESGCM gcmSt) f = B.copy gcmSt (f . castPtr) >>= \sm2 -> return (AESGCM sm2)

withOCBKeyAndCopySt :: AES -> AESOCB -> (Ptr AESOCB -> Ptr AES -> IO a) -> IO (a, AESOCB)
withOCBKeyAndCopySt aes (AESOCB gcmSt) f =
    keyToPtr aes $ \aesPtr -> do
        newSt <- B.copy gcmSt (\_ -> return ())
        a     <- withByteArray newSt $ \gcmStPtr -> f (castPtr gcmStPtr) aesPtr
        return (a, AESOCB newSt)

-- | Initialize a new context with a key
--
-- Key needs to be of length 16, 24 or 32 bytes. Any other values will return failure
initAES :: ByteArrayAccess key => key -> CryptoFailable AES
initAES k
    | len == 16 = CryptoPassed $ initWithRounds 10
    | len == 24 = CryptoPassed $ initWithRounds 12
    | len == 32 = CryptoPassed $ initWithRounds 14
    | otherwise = CryptoFailed CryptoError_KeySizeInvalid
  where len = B.length k
        initWithRounds nbR = AES $ B.allocAndFreeze (16+2*2*16*nbR) aesInit
        aesInit ptr = withByteArray k $ \ikey ->
            c_aes_init (castPtr ptr) (castPtr ikey) (fromIntegral len)

-- | encrypt using Electronic Code Book (ECB)
{-# NOINLINE encryptECB #-}
encryptECB :: ByteArray ba => AES -> ba -> ba
encryptECB = doECB c_aes_encrypt_ecb

-- | encrypt using Cipher Block Chaining (CBC)
{-# NOINLINE encryptCBC #-}
encryptCBC :: ByteArray ba
           => AES        -- ^ AES Context
           -> IV AES     -- ^ Initial vector of AES block size
           -> ba         -- ^ plaintext
           -> ba         -- ^ ciphertext
encryptCBC = doCBC c_aes_encrypt_cbc

-- | generate a counter mode pad. this is generally xor-ed to an input
-- to make the standard counter mode block operations.
--
-- if the length requested is not a multiple of the block cipher size,
-- more data will be returned, so that the returned bytestring is
-- a multiple of the block cipher size.
{-# NOINLINE genCTR #-}
genCTR :: ByteArray ba
       => AES    -- ^ Cipher Key.
       -> IV AES -- ^ usually a 128 bit integer.
       -> Int    -- ^ length of bytes required.
       -> ba
genCTR ctx (IV iv) len
    | len <= 0  = B.empty
    | otherwise = B.allocAndFreeze (nbBlocks * 16) generate
  where generate o = withKeyAndIV ctx iv $ \k i -> c_aes_gen_ctr (castPtr o) k i (fromIntegral nbBlocks)
        (nbBlocks',r) = len `quotRem` 16
        nbBlocks = if r == 0 then nbBlocks' else nbBlocks' + 1

-- | generate a counter mode pad. this is generally xor-ed to an input
-- to make the standard counter mode block operations.
--
-- if the length requested is not a multiple of the block cipher size,
-- more data will be returned, so that the returned bytestring is
-- a multiple of the block cipher size.
--
-- Similiar to 'genCTR' but also return the next IV for continuation
{-# NOINLINE genCounter #-}
genCounter :: ByteArray ba
           => AES
           -> IV AES
           -> Int
           -> (ba, IV AES)
genCounter ctx iv len
    | len <= 0  = (B.empty, iv)
    | otherwise = unsafeDoIO $
        keyToPtr ctx $ \k ->
        ivCopyPtr iv $ \i ->
        B.alloc outputLength $ \o -> do
            c_aes_gen_ctr_cont (castPtr o) k i (fromIntegral nbBlocks)
  where
        (nbBlocks',r) = len `quotRem` 16
        nbBlocks = if r == 0 then nbBlocks' else nbBlocks' + 1
        outputLength = nbBlocks * 16

{- TODO: when genCTR has same AESIV requirements for IV, add the following rules:
 - RULES "snd . genCounter" forall ctx iv len .  snd (genCounter ctx iv len) = genCTR ctx iv len
 -}

-- | encrypt using Counter mode (CTR)
--
-- in CTR mode encryption and decryption is the same operation.
{-# NOINLINE encryptCTR #-}
encryptCTR :: ByteArray ba
           => AES        -- ^ AES Context
           -> IV AES     -- ^ initial vector of AES block size (usually representing a 128 bit integer)
           -> ba         -- ^ plaintext input
           -> ba         -- ^ ciphertext output
encryptCTR ctx iv input
    | len <= 0          = B.empty
    | B.length iv /= 16 = error $ "AES error: IV length must be block size (16). Its length is: " ++ (show $ B.length iv)
    | otherwise = B.allocAndFreeze len doEncrypt
  where doEncrypt o = withKeyAndIV ctx iv $ \k v -> withByteArray input $ \i ->
                      c_aes_encrypt_ctr (castPtr o) k v i (fromIntegral len)
        len = B.length input

-- | encrypt using Galois counter mode (GCM)
-- return the encrypted bytestring and the tag associated
--
-- note: encrypted data is identical to CTR mode in GCM, however
-- a tag is also computed.
{-# NOINLINE encryptGCM #-}
encryptGCM :: (ByteArrayAccess iv, ByteArrayAccess aad, ByteArray ba)
           => AES        -- ^ AES Context
           -> iv         -- ^ IV initial vector of any size
           -> aad        -- ^ data to authenticate (AAD)
           -> ba         -- ^ data to encrypt
           -> (ba, AuthTag) -- ^ ciphertext and tag
encryptGCM = doGCM gcmAppendEncrypt

-- | encrypt using OCB v3
-- return the encrypted bytestring and the tag associated
{-# NOINLINE encryptOCB #-}
encryptOCB :: (ByteArrayAccess iv, ByteArrayAccess aad, ByteArray ba)
           => AES        -- ^ AES Context
           -> iv         -- ^ IV initial vector of any size
           -> aad        -- ^ data to authenticate (AAD)
           -> ba         -- ^ data to encrypt
           -> (ba, AuthTag) -- ^ ciphertext and tag
encryptOCB = doOCB ocbAppendEncrypt

-- | encrypt using XTS
--
-- the first key is the normal block encryption key
-- the second key is used for the initial block tweak
{-# NOINLINE encryptXTS #-}
encryptXTS :: ByteArray ba
           => (AES,AES)  -- ^ AES cipher and tweak context
           -> IV AES     -- ^ a 128 bits IV, typically a sector or a block offset in XTS
           -> Word32     -- ^ number of rounds to skip, also seen a 16 byte offset in the sector or block.
           -> ba         -- ^ input to encrypt
           -> ba         -- ^ output encrypted
encryptXTS = doXTS c_aes_encrypt_xts

-- | decrypt using Electronic Code Book (ECB)
{-# NOINLINE decryptECB #-}
decryptECB :: ByteArray ba => AES -> ba -> ba
decryptECB = doECB c_aes_decrypt_ecb

-- | decrypt using Cipher block chaining (CBC)
{-# NOINLINE decryptCBC #-}
decryptCBC :: ByteArray ba => AES -> IV AES -> ba -> ba
decryptCBC = doCBC c_aes_decrypt_cbc

-- | decrypt using Counter mode (CTR).
--
-- in CTR mode encryption and decryption is the same operation.
decryptCTR :: ByteArray ba
           => AES        -- ^ AES Context
           -> IV AES     -- ^ initial vector, usually representing a 128 bit integer
           -> ba         -- ^ ciphertext input
           -> ba         -- ^ plaintext output
decryptCTR = encryptCTR

-- | decrypt using XTS
{-# NOINLINE decryptXTS #-}
decryptXTS :: ByteArray ba
           => (AES,AES)  -- ^ AES cipher and tweak context
           -> IV AES     -- ^ a 128 bits IV, typically a sector or a block offset in XTS
           -> Word32     -- ^ number of rounds to skip, also seen a 16 byte offset in the sector or block.
           -> ba         -- ^ input to decrypt
           -> ba         -- ^ output decrypted
decryptXTS = doXTS c_aes_decrypt_xts

-- | decrypt using Galois Counter Mode (GCM)
{-# NOINLINE decryptGCM #-}
decryptGCM :: (ByteArrayAccess aad, ByteArrayAccess iv, ByteArray ba)
           => AES        -- ^ Key
           -> iv         -- ^ IV initial vector of any size
           -> aad        -- ^ data to authenticate (AAD)
           -> ba         -- ^ data to decrypt
           -> (ba, AuthTag) -- ^ plaintext and tag
decryptGCM = doGCM gcmAppendDecrypt

-- | decrypt using Offset Codebook Mode (OCB)
{-# NOINLINE decryptOCB #-}
decryptOCB :: (ByteArrayAccess aad, ByteArrayAccess iv, ByteArray ba)
           => AES        -- ^ Key
           -> iv         -- ^ IV initial vector of any size
           -> aad        -- ^ data to authenticate (AAD)
           -> ba         -- ^ data to decrypt
           -> (ba, AuthTag) -- ^ plaintext and tag
decryptOCB = doOCB ocbAppendDecrypt

{-# INLINE doECB #-}
doECB :: ByteArray ba
      => (Ptr b -> Ptr AES -> CString -> CUInt -> IO ())
      -> AES -> ba -> ba
doECB f ctx input
    | len == 0     = B.empty
    | r /= 0       = error $ "Encryption error: input length must be a multiple of block size (16). Its length is: " ++ (show len)
    | otherwise    =
        B.allocAndFreeze len $ \o ->
        keyToPtr ctx         $ \k ->
        withByteArray input  $ \i ->
            f (castPtr o) k i (fromIntegral nbBlocks)
  where (nbBlocks, r) = len `quotRem` 16
        len           = B.length input

{-# INLINE doCBC #-}
doCBC :: ByteArray ba
      => (Ptr b -> Ptr AES -> Ptr Word8 -> CString -> CUInt -> IO ())
      -> AES -> IV AES -> ba -> ba
doCBC f ctx (IV iv) input
    | len == 0  = B.empty
    | r /= 0    = error $ "Encryption error: input length must be a multiple of block size (16). Its length is: " ++ (show len)
    | otherwise = B.allocAndFreeze len $ \o ->
                  withKeyAndIV ctx iv $ \k v ->
                  withByteArray input $ \i ->
                  f (castPtr o) k v i (fromIntegral nbBlocks)
  where (nbBlocks, r) = len `quotRem` 16
        len           = B.length input

{-# INLINE doXTS #-}
doXTS :: ByteArray ba
      => (Ptr b -> Ptr AES -> Ptr AES -> Ptr Word8 -> CUInt -> CString -> CUInt -> IO ())
      -> (AES, AES)
      -> IV AES
      -> Word32
      -> ba
      -> ba
doXTS f (key1,key2) iv spoint input
    | len == 0  = B.empty
    | r /= 0    = error $ "Encryption error: input length must be a multiple of block size (16) for now. Its length is: " ++ (show len)
    | otherwise = B.allocAndFreeze len $ \o -> withKey2AndIV key1 key2 iv $ \k1 k2 v -> withByteArray input $ \i ->
            f (castPtr o) k1 k2 v (fromIntegral spoint) i (fromIntegral nbBlocks)
  where (nbBlocks, r) = len `quotRem` 16
        len           = B.length input

------------------------------------------------------------------------
-- GCM
------------------------------------------------------------------------

{-# INLINE doGCM #-}
doGCM :: (ByteArrayAccess iv, ByteArrayAccess aad, ByteArray ba)
      => (AES -> AESGCM -> ba -> (ba, AESGCM))
      -> AES
      -> iv
      -> aad
      -> ba
      -> (ba, AuthTag)
doGCM f ctx iv aad input = (output, tag)
  where tag             = gcmFinish ctx after 16
        (output, after) = f ctx afterAAD input
        afterAAD        = gcmAppendAAD ini aad
        ini             = gcmInit ctx iv

-- | initialize a gcm context
{-# NOINLINE gcmInit #-}
gcmInit :: ByteArrayAccess iv => AES -> iv -> AESGCM
gcmInit ctx iv = unsafeDoIO $ do
    sm <- B.alloc sizeGCM $ \gcmStPtr ->
            withKeyAndIV ctx iv $ \k v ->
            c_aes_gcm_init (castPtr gcmStPtr) k v (fromIntegral $ B.length iv)
    return $ AESGCM sm

-- | append data which is only going to be authenticated to the GCM context.
--
-- need to happen after initialization and before appending encryption/decryption data.
{-# NOINLINE gcmAppendAAD #-}
gcmAppendAAD :: ByteArrayAccess aad => AESGCM -> aad -> AESGCM
gcmAppendAAD gcmSt input = unsafeDoIO doAppend
  where doAppend =
            withNewGCMSt gcmSt $ \gcmStPtr ->
            withByteArray input $ \i ->
            c_aes_gcm_aad gcmStPtr i (fromIntegral $ B.length input)

-- | append data to encrypt and append to the GCM context
--
-- bytestring need to be multiple of AES block size, unless it's the last call to this function.
-- need to happen after AAD appending, or after initialization if no AAD data.
{-# NOINLINE gcmAppendEncrypt #-}
gcmAppendEncrypt :: ByteArray ba => AES -> AESGCM -> ba -> (ba, AESGCM)
gcmAppendEncrypt ctx gcm input = unsafeDoIO $ withGCMKeyAndCopySt ctx gcm doEnc
  where len = B.length input
        doEnc gcmStPtr aesPtr =
            B.alloc len $ \o ->
            withByteArray input $ \i ->
            c_aes_gcm_encrypt (castPtr o) gcmStPtr aesPtr i (fromIntegral len)

-- | append data to decrypt and append to the GCM context
--
-- bytestring need to be multiple of AES block size, unless it's the last call to this function.
-- need to happen after AAD appending, or after initialization if no AAD data.
{-# NOINLINE gcmAppendDecrypt #-}
gcmAppendDecrypt :: ByteArray ba => AES -> AESGCM -> ba -> (ba, AESGCM)
gcmAppendDecrypt ctx gcm input = unsafeDoIO $ withGCMKeyAndCopySt ctx gcm doDec
  where len = B.length input
        doDec gcmStPtr aesPtr =
            B.alloc len $ \o ->
            withByteArray input $ \i ->
            c_aes_gcm_decrypt (castPtr o) gcmStPtr aesPtr i (fromIntegral len)

-- | Generate the Tag from GCM context
{-# NOINLINE gcmFinish #-}
gcmFinish :: AES -> AESGCM -> Int -> AuthTag
gcmFinish ctx gcm taglen = AuthTag $ B.take taglen computeTag
  where computeTag = B.allocAndFreeze 16 $ \t ->
                        withGCMKeyAndCopySt ctx gcm (c_aes_gcm_finish (castPtr t)) >> return ()

------------------------------------------------------------------------
-- OCB v3
------------------------------------------------------------------------

{-# INLINE doOCB #-}
doOCB :: (ByteArrayAccess iv, ByteArrayAccess aad, ByteArray ba)
      => (AES -> AESOCB -> ba -> (ba, AESOCB))
      -> AES
      -> iv
      -> aad
      -> ba
      -> (ba, AuthTag)
doOCB f ctx iv aad input = (output, tag)
  where tag             = ocbFinish ctx after 16
        (output, after) = f ctx afterAAD input
        afterAAD        = ocbAppendAAD ctx ini aad
        ini             = ocbInit ctx iv

-- | initialize an ocb context
{-# NOINLINE ocbInit #-}
ocbInit :: ByteArrayAccess iv => AES -> iv -> AESOCB
ocbInit ctx iv = unsafeDoIO $ do
    sm <- B.alloc sizeOCB $ \ocbStPtr ->
            withKeyAndIV ctx iv $ \k v ->
            c_aes_ocb_init (castPtr ocbStPtr) k v (fromIntegral $ B.length iv)
    return $ AESOCB sm

-- | append data which is going to just be authenticated to the OCB context.
--
-- need to happen after initialization and before appending encryption/decryption data.
{-# NOINLINE ocbAppendAAD #-}
ocbAppendAAD :: ByteArrayAccess aad => AES -> AESOCB -> aad -> AESOCB
ocbAppendAAD ctx ocb input = unsafeDoIO (snd `fmap` withOCBKeyAndCopySt ctx ocb doAppend)
  where doAppend ocbStPtr aesPtr =
            withByteArray input $ \i ->
            c_aes_ocb_aad ocbStPtr aesPtr i (fromIntegral $ B.length input)

-- | append data to encrypt and append to the OCB context
--
-- bytestring need to be multiple of AES block size, unless it's the last call to this function.
-- need to happen after AAD appending, or after initialization if no AAD data.
{-# NOINLINE ocbAppendEncrypt #-}
ocbAppendEncrypt :: ByteArray ba => AES -> AESOCB -> ba -> (ba, AESOCB)
ocbAppendEncrypt ctx ocb input = unsafeDoIO $ withOCBKeyAndCopySt ctx ocb doEnc
  where len = B.length input
        doEnc ocbStPtr aesPtr =
            B.alloc len $ \o ->
            withByteArray input $ \i ->
            c_aes_ocb_encrypt (castPtr o) ocbStPtr aesPtr i (fromIntegral len)

-- | append data to decrypt and append to the OCB context
--
-- bytestring need to be multiple of AES block size, unless it's the last call to this function.
-- need to happen after AAD appending, or after initialization if no AAD data.
{-# NOINLINE ocbAppendDecrypt #-}
ocbAppendDecrypt :: ByteArray ba => AES -> AESOCB -> ba -> (ba, AESOCB)
ocbAppendDecrypt ctx ocb input = unsafeDoIO $ withOCBKeyAndCopySt ctx ocb doDec
  where len = B.length input
        doDec ocbStPtr aesPtr =
            B.alloc len $ \o ->
            withByteArray input $ \i ->
            c_aes_ocb_decrypt (castPtr o) ocbStPtr aesPtr i (fromIntegral len)

-- | Generate the Tag from OCB context
{-# NOINLINE ocbFinish #-}
ocbFinish :: AES -> AESOCB -> Int -> AuthTag
ocbFinish ctx ocb taglen = AuthTag $ B.take taglen computeTag
  where computeTag = B.allocAndFreeze 16 $ \t ->
                        withOCBKeyAndCopySt ctx ocb (c_aes_ocb_finish (castPtr t)) >> return ()

------------------------------------------------------------------------
foreign import ccall "cryptonite_aes.h cryptonite_aes_initkey"
    c_aes_init :: Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_encrypt_ecb"
    c_aes_encrypt_ecb :: CString -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_decrypt_ecb"
    c_aes_decrypt_ecb :: CString -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_encrypt_cbc"
    c_aes_encrypt_cbc :: CString -> Ptr AES -> Ptr Word8 -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_decrypt_cbc"
    c_aes_decrypt_cbc :: CString -> Ptr AES -> Ptr Word8 -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_encrypt_xts"
    c_aes_encrypt_xts :: CString -> Ptr AES -> Ptr AES -> Ptr Word8 -> CUInt -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_decrypt_xts"
    c_aes_decrypt_xts :: CString -> Ptr AES -> Ptr AES -> Ptr Word8 -> CUInt -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_gen_ctr"
    c_aes_gen_ctr :: CString -> Ptr AES -> Ptr Word8 -> CUInt -> IO ()

foreign import ccall unsafe "cryptonite_aes.h cryptonite_aes_gen_ctr_cont"
    c_aes_gen_ctr_cont :: CString -> Ptr AES -> Ptr Word8 -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_encrypt_ctr"
    c_aes_encrypt_ctr :: CString -> Ptr AES -> Ptr Word8 -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_gcm_init"
    c_aes_gcm_init :: Ptr AESGCM -> Ptr AES -> Ptr Word8 -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_gcm_aad"
    c_aes_gcm_aad :: Ptr AESGCM -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_gcm_encrypt"
    c_aes_gcm_encrypt :: CString -> Ptr AESGCM -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_gcm_decrypt"
    c_aes_gcm_decrypt :: CString -> Ptr AESGCM -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_gcm_finish"
    c_aes_gcm_finish :: CString -> Ptr AESGCM -> Ptr AES -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_ocb_init"
    c_aes_ocb_init :: Ptr AESOCB -> Ptr AES -> Ptr Word8 -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_ocb_aad"
    c_aes_ocb_aad :: Ptr AESOCB -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_ocb_encrypt"
    c_aes_ocb_encrypt :: CString -> Ptr AESOCB -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_ocb_decrypt"
    c_aes_ocb_decrypt :: CString -> Ptr AESOCB -> Ptr AES -> CString -> CUInt -> IO ()

foreign import ccall "cryptonite_aes.h cryptonite_aes_ocb_finish"
    c_aes_ocb_finish :: CString -> Ptr AESOCB -> Ptr AES -> IO ()

