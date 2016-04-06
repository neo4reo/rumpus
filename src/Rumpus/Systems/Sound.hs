{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
module Rumpus.Systems.Sound where
import PreludeExtra

import Rumpus.Systems.Shared
import Rumpus.Systems.Selection
import Rumpus.Systems.Hands
data SoundSystem = SoundSystem 
    { _sndPd               :: !PureData
    , _sndOpenALSourcePool :: ![(Int, OpenALSource)]
    }
makeLenses ''SoundSystem
defineSystemKey ''SoundSystem

defineComponentKeyWithType "PdPatch"     [t|Patch|]
defineComponentKeyWithType "PdPatchFile" [t|FilePath|]
defineComponentKey ''OpenALSource

addPdPatchSearchPath :: (MonadIO m, MonadState ECS m) => String -> m ()
addPdPatchSearchPath path = do
    pd <- viewSystem sysSound sndPd
    addToLibPdSearchPath pd path

initSoundSystem :: (MonadState ECS m, MonadIO m) => PureData -> m ()
initSoundSystem pd = do
    mapM_ (addToLibPdSearchPath pd)
        ["resources/pd-kit", "resources/pd-kit/list-abs"]

    let soundSystem = SoundSystem { _sndPd = pd, _sndOpenALSourcePool = zip [1..] (pdSources pd) }

    registerSystem sysSound soundSystem

    registerComponent "PdPatchFile" cmpPdPatchFile (savedComponentInterface cmpPdPatchFile)
    registerComponent "OpenALSource" cmpOpenALSource (newComponentInterface cmpOpenALSource)
    registerComponent "PdPatch" cmpPdPatch $ (newComponentInterface cmpPdPatch)
        { ciDeriveComponent = Just (derivePdPatchComponent pd) 
        , ciRemoveComponent = removePdPatchComponent 
        }

tickSoundSystem :: (MonadIO m, MonadState ECS m) => m ()
tickSoundSystem = do
    headM44 <- getHeadPose 
    -- Update source and listener positions
    alListenerPose (poseFromMatrix headM44)
    forEntitiesWithComponent cmpOpenALSource $ \(entityID, sourceID) -> do
        position <- view translation <$> getEntityPose entityID
        alSourcePosition sourceID position

dequeueOpenALSource :: MonadState ECS m => m (Maybe (Int, OpenALSource))
dequeueOpenALSource = modifySystemState sysSound $ do
    openALSourcePool <- use sndOpenALSourcePool
    case openALSourcePool of
        [] -> return Nothing
        (x:xs) -> do
            sndOpenALSourcePool .= xs ++ [x]
            return (Just x)

derivePdPatchComponent :: (MonadReader EntityID m, MonadState ECS m, MonadIO m) => PureData -> m ()
derivePdPatchComponent pd = do
    withComponent_ cmpPdPatchFile $ \patchFile -> do
        sceneFolder <- getSceneFolder
        patch <- makePatch pd (sceneFolder </> takeBaseName patchFile)
        cmpPdPatch ==> patch

        -- Assign the patch's output DAC index to route it to the the SourceID
        traverseM_ dequeueOpenALSource $ \(sourceChannel, sourceID) -> do
            putStrLnIO $ "loaded pd patch " ++ patchFile ++ ", assigning channel " ++ show sourceChannel
            send pd patch "dac" $ Atom (fromIntegral sourceChannel)
            cmpOpenALSource ==> sourceID

removePdPatchComponent :: (MonadReader EntityID m, MonadIO m, MonadState ECS m) => m ()
removePdPatchComponent = do
    pd <- viewSystem sysSound sndPd
    _ <- withPdPatch $ closePatch pd

    removeComponent cmpPdPatch
    removeComponent cmpOpenALSource

withPdPatch :: (MonadReader EntityID m, MonadState ECS m) => (Patch -> m b) -> m (Maybe b)
withPdPatch = withComponent cmpPdPatch


withEntityPdPatch :: (HasComponents s, MonadState s m) => EntityID -> (Patch -> m b) -> m (Maybe b)
withEntityPdPatch entityID = withEntityComponent entityID cmpPdPatch

sendToPdPatch :: (MonadIO m, MonadState ECS m) => Patch -> Receiver -> Message -> m ()
sendToPdPatch patch receiver message = withSystem_ sysSound $ \soundSystem -> 
    send (soundSystem ^. sndPd) patch receiver message

sendEntityPd :: (MonadIO m, MonadState ECS m) => EntityID -> Receiver -> Message -> m ()
sendEntityPd entityID receiver message = 
    void . withEntityPdPatch entityID $ \patch -> 
        sendToPdPatch patch receiver message

sendPd :: (MonadIO m, MonadState ECS m, MonadReader EntityID m) => Receiver -> Message -> m ()
sendPd receiver message = 
    void . withPdPatch $ \patch -> 
        sendToPdPatch patch receiver message


readPdArray :: (MonadReader EntityID m, MonadIO m, MonadState ECS m, Integral a) => Receiver -> a -> a -> m [Double]
readPdArray arrayName offset count = do
    pd <- viewSystem sysSound sndPd
    fromMaybe [] . join <$> withPdPatch (\patch ->
        readArray pd (local patch arrayName) offset count)
