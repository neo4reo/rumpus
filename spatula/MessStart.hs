module MessStart where
import Rumpus

start :: OnStart
start _entityID = do
    forM_ [1..20::Int] $ \_ -> do
        color <- liftIO $ randomRIO (0,1)
        traverseM_ (spawnEntity Transient "MessyBall") $ 
            setEntityColor (color & _w .~ 1)
        traverseM_ (spawnEntity Transient "SoundCube") $ 
            setEntityColor (color & _w .~ 1)
    return Nothing
