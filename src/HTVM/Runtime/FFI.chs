-- | Module defines wrappers for DLPack messages which are used by TVM to pass
-- to/from models

-- {-# OPTIONS_GHC -fwarn-unused-imports #-}
-- {-# OPTIONS_GHC -fwarn-missing-signatures #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE FlexibleContexts #-}


module HTVM.Runtime.FFI where

import qualified Data.Array as Array

import Control.Exception (Exception, throwIO)
import Control.Arrow ((***))
import Control.Monad (forM_)
import Data.Array (Array(..))
import Data.ByteString (ByteString,pack)
import Data.Word (Word8,Word16,Word32,Word64)
import Data.Int (Int8,Int16,Int32,Int64)
import Data.Bits (FiniteBits(..),(.&.),shiftR)
import Data.Tuple (swap)
import Data.Text (Text)
import Foreign (ForeignPtr, newForeignPtr, Ptr, Storable(..), alloca, allocaArray, peek,
                plusPtr, poke, pokeArray, castPtr, advancePtr, malloc, mallocArray, FunPtr(..), free)
import Foreign.C.Types (CInt, CLong)
import Foreign.C.String (CString, withCString, peekCAString)
import System.IO.Unsafe (unsafePerformIO)

import HTVM.Prelude


data TVMError =
    TVMAllocFailed Int
  | TVMFreeFailed Int
  | TVMModLoadFailed Int String
  | TVMFuncLoadFailed Int String
  | TVMFunCallFailed Int
  | TVMFunCallBadType Int
  deriving(Show,Read,Ord,Eq)

instance Exception TVMError


#include <dlpack/dlpack.h>
#include <tvm/runtime/c_runtime_api.h>

{# enum DLDataTypeCode as TVMDataTypeCode {upcaseFirstLetter} deriving(Eq) #}
{# enum DLDeviceType as TVMDeviceType {upcaseFirstLetter} deriving(Eq) #}

{# enum TVMDeviceExtType {upcaseFirstLetter} deriving(Eq) #}
{# enum TVMTypeCode {upcaseFirstLetter} deriving(Eq) #}

instance Storable TVMTypeCode where
  sizeOf _ = {# sizeof TVMTypeCode #}
  alignment _ = {# alignof TVMTypeCode #}
  peek pc = toEnum <$> peek (castPtr pc)
  poke pc c = poke (castPtr pc) (fromEnum c)

type TVMShapeIndex = {# type tvm_index_t #}
type TVMDeviceId = Int

data TVMContext

instance Storable TVMContext where
  sizeOf _ = {# sizeof TVMContext #}
  alignment _ = {# alignof TVMContext #}
  peek = error "peek undefined"
  poke = error "poke undefined"

data TVMTensor

instance Storable TVMTensor where
  sizeOf _ = {# sizeof DLTensor #}
  alignment _ = {# alignof DLTensor #}
  peek = error "peek undefined"
  poke = error "poke undefined"

data TVMValue

instance Storable TVMValue where
  sizeOf _ = {# sizeof TVMValue #}
  alignment _ = {# alignof TVMValue #}
  peek = error "peek undefined"
  poke = error "poke undefined"

type TVMModule = Ptr ()
type TVMFunction = Ptr ()

setTensor :: Ptr TVMTensor -> Ptr TVMValue -> Ptr TVMTypeCode -> IO ()
setTensor pt pv pc = do
  poke pc KArrayHandle
  {# set TVMValue.v_handle #} pv (castPtr pt)

-- setStr :: String -> Ptr TVMValue -> Ptr TVMTypeCode -> IO ()
-- setStr s pv pc = undefined

foreign import ccall unsafe "c_runtime_api.h TVMArrayAlloc"
  tvmArrayAlloc
    :: Ptr TVMShapeIndex
                     -- shape
    -> Int           -- ndim,
    -> Int           -- dtype_code,
    -> Int           -- dtype_bits,
    -> Int           -- dtype_lanes,
    -> Int           -- device_type,
    -> Int           -- device_id,
    -> Ptr TVMTensor -- DLTensor* out
    -> IO Int

foreign import ccall unsafe "c_runtime_api.h TVMArrayFree"
  tvmArrayFree :: Ptr TVMTensor -> IO CInt

foreign import ccall unsafe "c_runtime_api.h TVMArrayFree"
  tvmArrayFree_ :: FunPtr (Ptr TVMTensor -> IO ())



class TVMIndex i where
  tvmList :: i -> [Integer]

instance TVMIndex Integer where tvmList a = [a]
instance TVMIndex (Integer,Integer) where tvmList (a,b) = [a,b]
instance TVMIndex (Integer,Integer,Integer) where tvmList (a,b,c) = [a,b,c]
instance TVMIndex (Integer,Integer,Integer,Integer) where tvmList (a,b,c,d) = [a,b,c,d]

tvmIndexDims :: (TVMIndex i) => i -> Integer
tvmIndexDims = ilength . tvmList

class TVMElemType e where
  tvmTypeCode :: TVMDataTypeCode
  tvmTypeBits :: Integer
  -- | Make a parameter of type
  tvmTypeLanes :: Integer

instance TVMElemType Int32 where tvmTypeCode = KDLInt; tvmTypeBits = 32; tvmTypeLanes = 1
instance TVMElemType Float where tvmTypeCode = KDLFloat; tvmTypeBits = 32; tvmTypeLanes = 1
instance TVMElemType Word64 where tvmTypeCode = KDLUInt; tvmTypeBits = 64; tvmTypeLanes = 1

-- | Data source. @d@ is type of data, @i@ is a type of index, @e@ is a type of element
class (TVMIndex i, TVMElemType e) => TVMData d i e | d -> i, d -> e where
  tvmIShape :: d -> [Integer]
  tvmIndex :: d -> i -> IO e
  tvmPeek :: Ptr e -> IO d
  tvmPoke :: d -> Ptr e -> IO ()

instance (Storable e, Array.Ix i, TVMIndex i, TVMElemType e) => TVMData (Array i e) i e where
  tvmIShape = map (uncurry (-)) . uncurry zip . (tvmList *** tvmList) . Array.bounds
  tvmIndex d i = pure $ d Array.! i
  tvmPoke d ptr = pokeArray ptr (Array.elems d)

tvmIShape1 d = [ilength d]
tvmIndex1 l i = pure $ l !! (fromInteger i)
tvmPoke1 d ptr = pokeArray ptr d
instance TVMData [Float] Integer Float where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1
instance TVMData [Int32] Integer Int32 where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1
instance TVMData [Word64] Integer Word64 where tvmIShape = tvmIShape1 ; tvmIndex = tvmIndex1; tvmPoke = tvmPoke1

tvmIShape2 d = [ilength d, ilength (head d)]
tvmIndex2 l (r,c) = pure $ l !! (fromInteger r) !! (fromInteger c)
tvmPoke2 d ptr = pokeArray ptr (concat d)
instance TVMData [[Float]] (Integer,Integer) Float where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2
instance TVMData [[Int32]] (Integer,Integer) Int32 where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2
instance TVMData [[Word64]] (Integer,Integer) Word64 where tvmIShape = tvmIShape2 ; tvmIndex = tvmIndex2; tvmPoke = tvmPoke2

tvmDataShape :: (TVMData d i e) => d -> [Integer]
tvmDataShape = tvmIShape

tvmDataDims :: (TVMData d i e) => d -> Integer
tvmDataDims = ilength . tvmDataShape

--tvmDataTypeCode :: forall d i e . (TVMData d i e) => d -> TVMDataTypeCode
--tvmDataTypeCode _ = tvmTypeCode (Proxy :: Proxy e)


newTensor :: forall d i e b . (TVMData d i e)
          => d                           -- ^ TvmData tensor-like object
          -> TVMDeviceType               -- ^ Device type
          -> TVMDeviceId                 -- ^ Device ID
          -> IO (ForeignPtr TVMTensor)
newTensor d dt did =
  let
    shape = map fromInteger $ tvmDataShape d
    ndim = fromInteger $ tvmDataDims d
  in do
  pt <- malloc
  r <- allocaArray ndim $ \pshape -> do
         pokeArray pshape shape
         tvmArrayAlloc
            pshape ndim
            (fromEnum $ tvmTypeCode @e)
            (fromInteger $ tvmTypeBits @e)
            (fromInteger $ tvmTypeLanes @e)
            (fromEnum dt)
            did pt
  case r of
    0 -> do
      {- Copying data from TVMData d-}
      pdata <- {# get DLTensor->data #} pt
      tvmPoke d (castPtr pdata)
      newForeignPtr tvmArrayFree_ pt
    e -> throwIO (TVMAllocFailed e)






withTensorInput :: forall d i e b . (TVMData d i e)
              => d                           -- ^ TvmData tensor-like object
              -> TVMDeviceType               -- ^ Device type
              -> TVMDeviceId                 -- ^ Device ID
              -> (Ptr TVMTensor -> IO b)     -- ^ Handler funtion
              -> IO b
withTensorInput d dt did f = do
  alloca $ \ptensor ->
    let
      shape = map fromInteger $ tvmDataShape d
      ndim = fromInteger $ tvmDataDims d
    in
    allocaArray ndim $ \pshape -> do
      pokeArray pshape shape
      r <- tvmArrayAlloc
              pshape ndim
              (fromEnum $ tvmTypeCode @e)
              (fromInteger $ tvmTypeBits @e)
              (fromInteger $ tvmTypeLanes @e)
              (fromEnum dt)
              did
              ptensor
      case r of
        0 -> do
          {- Copying data from TVMData d-}
          pdata <- {# get DLTensor->data #} ptensor
          tvmPoke d (castPtr pdata)
          {- Calling user handler -}
          b <- f ptensor
          r2 <- tvmArrayFree ptensor
          case r of
            0 -> return b
            e -> throwIO (TVMFreeFailed e)
        e -> throwIO (TVMAllocFailed e)

withTensorOutput :: forall d i e b . (TVMData d i e)
              => [Integer]
              -> TVMDeviceType
              -> TVMDeviceId
              -> (Ptr TVMTensor -> IO b)
              -> IO (d,b)
withTensorOutput shape dt did f = do
  alloca $ \ptensor ->
    let
      ndim = length shape
    in
    allocaArray ndim $ \pshape -> do
      pokeArray pshape (map (fromInteger . toInteger) shape)
      r <- tvmArrayAlloc
              pshape ndim
              (fromEnum $ tvmTypeCode @e)
              (fromInteger $ tvmTypeBits @e)
              (fromInteger $ tvmTypeLanes @e)
              (fromEnum dt)
              did
              ptensor
      case r of
        0 -> do
          {- Calling user handler -}
          b <- f ptensor
          {- Copying data from TVMData d-}
          pdata <- {# get DLTensor->data #} ptensor
          d <- tvmPeek (castPtr pdata)
          r <- tvmArrayFree ptensor
          case r of
            0 -> return (d,b)
            e -> throwIO (TVMFreeFailed $ fromInteger $ toInteger e)
        e -> throwIO (TVMAllocFailed e)

foreign import ccall unsafe "c_runtime_api.h TVMModLoadFromFile"
  tvmModLoadFromFile :: CString -> CString -> Ptr TVMModule -> IO CInt

foreign import ccall unsafe "c_runtime_api.h TVMModGetFunction"
  tvmModGetFunction :: TVMModule -> CString -> CInt -> Ptr TVMFunction -> IO CInt

foreign import ccall unsafe "c_runtime_api.h TVMGetLastError"
  tvmGetLastError :: IO CString

foreign import ccall unsafe "c_runtime_api.h TVMFuncCall"
  tvmFuncCall :: TVMFunction -> Ptr TVMValue -> Ptr TVMTypeCode -> CInt -> Ptr TVMValue -> Ptr TVMTypeCode -> IO CInt

getLastError :: IO String
getLastError = peekCAString =<< tvmGetLastError

-- | Load module from 'so' dynamic library
-- TODO: Unload the module
-- TODO: Pass GetLastError in case of failure
withModule :: Text -> (TVMModule -> IO b) -> IO b
withModule modname func =
  alloca $ \pmod -> do
  withCString (tunpack modname) $ \cmodname -> do
  withCString "so" $ \so -> do
    r <- tvmModLoadFromFile cmodname so pmod
    case r of
      0 -> func =<< peek pmod
      err -> do
        str <- getLastError
        throwIO (TVMModLoadFailed (fromInteger $ toInteger err) str)

-- | Load the function from module
-- TODO: Unload the module
-- TODO: Pass GetLastError in case of failure
withFunction :: Text -> TVMModule -> (TVMFunction -> IO b) -> IO b
withFunction funcname mod func =
  alloca $ \pfunc -> do
  withCString (tunpack funcname) $ \cfuncname -> do
    r <- tvmModGetFunction mod cfuncname 0 pfunc
    case r of
      0 -> func =<< peek pfunc
      err -> do
        str <- getLastError
        throwIO (TVMFuncLoadFailed (fromInteger $ toInteger err) str)

callTensorFunction :: forall d i e . (TVMData d i e) => [Integer] -> TVMFunction -> [d] -> IO d
callTensorFunction oshape fun ts0 =
  let
    devtype = KDLCPU
    devid = 0
    go pts (t:ts) = withTensorInput t devtype devid $ \pt -> go (pt:pts) ts
    go pts [] = withTensorOutput oshape devtype devid $ \pto -> do
      alloca $ \pret -> do
      alloca $ \pretcode -> do
      allocaArray (length pts) $ \pv -> do
      allocaArray (length pts) $ \pc -> do
        forM_ (pts`zip`[0..(length pts)-1]) $ \(pt,off) -> do
          setTensor pt (advancePtr pv off) (advancePtr pc off)
        setTensor pto pret pretcode
        let clen = fromInteger $ toInteger $ length pts
        r <- tvmFuncCall fun pv pc clen pret pretcode
        rt <- peek pretcode
        case (r,rt) of
          (0,KArrayHandle) -> do
            return ()
          (x,KArrayHandle) -> do
            throwIO (TVMFunCallFailed $ fromInteger $ toInteger x)
          (0,t) -> do
            throwIO (TVMFunCallBadType $ fromEnum rt)
  in
  fst <$> go [] ts0

{-
TVM_DLL int TVMModGetFunction(TVMModuleHandle mod,
                              const char* func_name,
                              int query_imports,
                              TVMFunctionHandle *out);
-}

{-
foreign import ccall unsafe "dlfcn.h dlopen"
  dlopen :: CString -> Int -> IO (Ptr ModuleHandle)
foreign import ccall unsafe "dlfcn.h dlclose"
  dlclose :: Ptr ModuleHandle -> IO ()
-}



{-

{#
enum mtl_Formula_type as Mtl_Formula_Type {upcaseFirstLetter}
    deriving (Eq, Show)
#}



instance Storable ??? where
    sizeOf _ = {# sizeof mtl_State #} + maxSubformulas * {# sizeof mtl_Payload #}
    alignment _ = {# alignof mtl_Formula #}
    peek = error ("peek is not implemented for the State datatype")
    poke mptr ??? = do
        let sf = unfold f
        when (length sf > maxSubformulas) $
            fail $ "Subformulas number limit (" ++ show maxSubformulas ++ ") is reached"
        let ppl num =
                mptr
                `plusPtr` {# sizeof mtl_State #}
                `plusPtr` (num * {# sizeof mtl_Formula_subf #})
        {# set mtl_State.pl #} mptr (ppl 0)
        {# set mtl_State.pl_size #} mptr (fromIntegral $ length sf)

-- | Represents the immutable part of a formula on the C-side
instance Storable ??? where
    sizeOf _ = {# sizeof mtl_Formula #}
    alignment _ = {# alignof mtl_Formula #}
    peek = error ("peek is not implemented for the Formula datatype")
    poke iptr ??? = do
        let sf = unfold f
        when (length sf > maxSubformulas) $
            fail $ "Subformulas number limit (" ++ show maxSubformulas ++ ") is reached"

        let -- | Returns pointer to subformula @n@, the array os stored after mtl_Formula
            psubf num =
                iptr
                `plusPtr` {# sizeof mtl_Formula #}
                `plusPtr` (num * {# sizeof mtl_Formula_subf #})

        {# set mtl_Formula.subf #} iptr (psubf 0)
        {# set mtl_Formula.subf_size #} iptr (fromIntegral $ length sf)
        for_ (sf `zip` [0 ..]) $ \(f', i) -> do
            {# set mtl_Formula_subf.t #} (psubf i) (ft2ct (ftype f'))
            {# set mtl_Formula_subf.argn #} (psubf i) (fromIntegral . fromMaybe (-1) $ argn f')
            {# set mtl_Formula_subf.nm.pname #} (psubf i)
                (case predA f' of
                    Just (PName nm1) -> fromIntegral $ hash nm1
                    Nothing -> -1
                )
            {# set mtl_Formula_subf.p1.pos #} (psubf i) (fromIntegral $ fromMaybe (-1) $ (fst <$> snd <$> payload <$> subfn 0 f'))
            {# set mtl_Formula_subf.p2.pos #} (psubf i) (fromIntegral $ fromMaybe (-1) $ (fst <$> snd <$> payload <$> subfn 1 f'))

-}
