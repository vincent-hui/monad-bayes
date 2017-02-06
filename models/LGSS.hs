{-# LANGUAGE
 FlexibleContexts,
 TypeFamilies
 #-}

module Main where

import Data.List (transpose)
import Data.Vector (Vector, fromList, foldM, postscanl)
import qualified Data.Vector as Vector
import Data.Bifunctor (second)
import Graphics.Rendering.Chart.Easy hiding (Vector)
import Graphics.Rendering.Chart.Backend.Cairo (toFile, fo_format, FileFormat(PDF))
import Options.Applicative
import System.Directory
import Control.Monad.Trans
import System.IO
import Control.Monad (when, unless)

import Control.Monad.Bayes.Primitive
import Control.Monad.Bayes.Class
import Control.Monad.Bayes.Prior
import Control.Monad.Bayes.Sampler
import Control.Monad.Bayes.Population
import Control.Monad.Bayes.Inference
import Control.Monad.Bayes.Kernel
import Control.Monad.Bayes.Trace

import Plotting

main = do
  -- make sure `putStrLn` prints to console immediately
  hSetBuffering stdout LineBuffering

  (trial, cachePath) <- execParser opts
  when trial $ putStrLn "Trial run"

  if not trial then do
    sampleIO $ lgssBenchmark cachePath 50 100 (map (2^) [1..10])
  else do
    sampleIO $ lgssBenchmark cachePath 5 10 [10,20,40]

opts :: ParserInfo (Bool,FilePath)
opts = flip info fullDesc ((,) <$> trialFlag <*> cacheDir) where
  trialFlag = switch
    ( long "trial"
    <> help "Run a quick version of benchmarks to check that all is working correctly.")
  cacheDir = strOption
    ( long "cache-dir"
    <> value "cache/lgss/"
    <> help "Directory to store temporary data that may be reused accross different runs.")

lgssBenchmark :: FilePath -> Int -> Int -> [Int] -> SamplerIO ()
lgssBenchmark cachePath t nRuns ns = do
  liftIO $ putStrLn "running LGSS benchmark"

  let plotPath = "lgss.pdf"

  let param = LGSSParam (0,1) 1 0 1 1 0 1
  let kernel = compose (gaussian 1) (last . fst . toLists)
  let gKernel = unsafeKernel (\xs ys -> evalKernel (gaussian (fromIntegral (1 + t - length xs))) (last xs) (last ys))
  let newKernel = compose (gKernel) (fst . toLists)

  scores <- sequence $ replicate nRuns $ do
    ys <- synthesizeData param t
    ref <- return $ kalman param ys
    let run m = do -- RMSE on the mean of filetering distribution
          estMean <- popAvg Vector.last (normalize m)
          let trueMean = fst (Vector.last ref)
          return $ abs (trueMean - estMean)
    smcRes <- mapM (\n -> run $ smc t n (linearGaussian param ys)) ns
    kernelRes <- mapM (\n -> run $ smcHerdingResample kernel t n (linearGaussian param ys)) ns
    newKernelRes <- mapM (\n -> run $ smcHerdingResample newKernel t n (linearGaussian param ys)) ns
    return (smcRes, kernelRes, newKernelRes)

  let (smcScores, kernelScores, newKernelScores) = unzip3 scores
  let smcPoints = zip (map fromIntegral ns) (transpose smcScores)
  let kernelPoints = zip (map fromIntegral ns) (transpose kernelScores)
  let newKernelPoints = zip (map fromIntegral ns) (transpose newKernelScores)

  liftIO $ toFile (fo_format .~ PDF $ def) plotPath $ do
    layout_title .= "LGSS"
    errorbarPlot "#samples" "RMSE" [
      ("SMC", smcPoints),
      ("Herding", kernelPoints),
      ("NewHerding", newKernelPoints)]

type Mean = Double
type StdDev = Double
type Linear = (Double,Double)

data LGSSParam = LGSSParam
  {
  p0 :: (Mean, StdDev), -- ^ initial state X0 prior
  a :: Double, -- ^ transition model slope
  b :: Double, -- ^ transition model intercept
  sdX :: StdDev, -- ^ transition model noise
  c :: Double, -- ^ observation model slope
  d :: Double, -- ^ observation model intercept
  sdY :: StdDev -- ^ observation model noise
  }

-- \ One-dimensional linear Gaussian state space model.
linearGaussian :: (MonadBayes m, CustomReal m ~ Double)
               => LGSSParam
               -> Vector Double -- ^ observed sequence Y_{1:T}
               -> m (Vector Double) -- ^ latent sequence posterior X_{1:T}
linearGaussian (LGSSParam p0 a b sdX c d sdY) ys = do
  let step xs y = do{
    x' <- normal (a*(head xs) + b) sdX;
    observe (Continuous (Normal (c*x' + d) sdY)) y;
    return (x':xs)}

  x0 <- uncurry normal p0
  ps <- foldM step [x0] ys
  return $ fromList $ tail $ reverse ps

-- | One-dimensional random walk with Gaussian diffusion.
randomWalk :: (MonadBayes m, CustomReal m ~ Double)
           => (Mean, StdDev) -- ^ initial state X0 prior
           -> StdDev -- ^ transition model noise
           -> StdDev -- ^ observation model noise
           -> Vector Double -- ^ observed sequence Y_{1:T}
           -> m (Vector Double)
randomWalk p0 sdX sdY ys = linearGaussian (LGSSParam p0 1 0 sdX 1 0 sdY) ys

-- | Generate observed sequence from the prior.
synthesizeData :: (MonadDist m, CustomReal m ~ Double)
             => LGSSParam
             -> Int -- ^ T - length of producted vector
             -> m (Vector Double) -- ^ data Y_{1:T} generated from the prior
synthesizeData param t = do
  xs <- prior $ linearGaussian param $ Vector.replicate t undefined
  Vector.mapM (\x -> normal (c param * x + d param) (sdY param)) xs

-- | Kalman filter computing exact filtering distributions X_t|Y_{1:t}.
kalman :: LGSSParam
       -> Vector Double
       -> Vector (Mean, StdDev)
kalman (LGSSParam (m0,sd0) a b sdX c d sdY) ys =
  Vector.map (second sqrt) $ postscanl step (m0, var0) ys where
    var0 = sd0 * sd0
    varX = sdX * sdX
    varY = sdY * sdY
    step (m,s) y = (m'',s'') where
      -- TODO: check the math here
      m' = a*m + b
      s' = a*a*s + varX
      v = y - c*m' - d
      h = c*c*s' + varY
      k = c*s' / h
      m'' = m' + k*v
      s'' = s' - k*k*h
