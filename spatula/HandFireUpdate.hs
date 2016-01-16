{-# LANGUAGE LambdaCase #-}
module HandFireUpdate where
import Rumpus

update :: OnUpdate
update entityID = do
    withRightHandEvents $ \case
        HandButtonEvent HandButtonTrigger ButtonDown -> do
            handPose <- getEntityPose entityID
            traverseM_ (spawnEntity Transient "MessyBall")
                (setEntityPose handPose)
        _ -> return ()
