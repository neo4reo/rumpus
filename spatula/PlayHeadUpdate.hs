module PlayHeadUpdate where
import Rumpus

update :: OnUpdate
update entityID = do
    x <- (/4) . flip mod' 4 <$> getNow
    printIO x
    let newPose_ = newPose & posPosition .~ V3 x 1 0
    setEntityPose newPose_ entityID
