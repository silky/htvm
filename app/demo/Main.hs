{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import qualified Data.Text.IO as Text

import Control.Monad(when)
import Control.Monad.Trans(liftIO)
import Control.Concurrent(forkIO)
import Data.Text(Text)

import HTVM
import MNIST

printFunction :: LoweredFunc -> IO ()
printFunction f =
  Text.putStrLn =<< withLineNumbers <$> showLoweredFuncCpp defaultConfig f

demo1 :: StmtT IO LModule
demo1 = do
  sa <- shapevar [5]

  a <- assign $ placeholder "A" float32 sa
  c <- compute sa $ \i -> (a![i])*(a![i])
  f1 <- lower "asquare" (schedule [c]) [a,c]

  liftIO $ putStrLn "asquare" >> printFunction f1

  dc <- assign $ (differentiate c [a]) ! 0
  f2 <- lower "d_asquare" (schedule [dc]) [a,dc]

  liftIO $ putStrLn "d_asquare" >> printFunction f2

  lmodul [f1,f2]


{-
model :: IO (ModuleLib LModule)
model = do
  buildLModule CPU defaultConfig "demo1.so" demo1 >>= do
  withLModule

    sa <- shapevar [1]
    function "difftest" [("A",float32,sa) ] $ \[a] -> do
      c <- compute sa $ \i -> (a![i])*(a![i])
      dc <- assign $ differentiate c [a]
      return (dc!0)

conv2d :: IO (ModuleLib LModule)
conv2d = do
  stageBuildFunction defaultConfig "model.so" $
    let
      num_classes = 10
      batch_size = 10
      img_h = 28
      img_w = 28
      img_c = 1

      f1_c = 4
      -- f2_c = 5
      -- f3_units = 16
    in do
    x_shape <- shapevar [batch_size, img_h, img_w, img_c]
    y_shape <- shapevar [batch_size, num_classes]
    function "demo" [("X", float32, x_shape)
                    ,("y", float32, y_shape)
                    ,("w1", float32, shp [3,3,img_c,f1_c])
                    ,("b1", float32, shp [f1_c])
                    ] $ \[x,y,w1,b1] -> do

      t <- assign $ conv2d_nchw x w1 def
      t <- assign $ t + broadcast_to b1 (shp [batch_size,1,1,f1_c])
      t <- assign $ relu t
      t <- assign $ flatten t
      return t

-}

main :: IO ()
main = do
  smod <- stageStmtT demo1
  bmod <- buildLModule defaultBackend defaultConfig "demo" smod
  hmod <- loadModule bmod

  a <- newTensor BackendLLVM 0 TD_Float32L1 [1..5 :: Word32]
  c <- newEmptyTensor BackendLLVM 0 TD_Float32L1 [5]

  callModule hmod "asquare" [a,c]

  putStrLn . show =<< getTensor @[Float] c
  return ()

