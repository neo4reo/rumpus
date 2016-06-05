{-# LANGUAGE OverloadedStrings #-}

module Rumpus.Main where
import Rumpus
import Halive.Recompiler
--import Rumpus.TestScene

{-
fft wraparound that excites sine bank with decay
do things to orient to hands to demonstrate symbiosis
-}

initializeECS :: TChan CompilationRequest -> PureData -> VRPal -> ECSMonad ()
initializeECS ghc pd vrPal = do
    initAnimationSystem
    initAttachmentSystem
    initClockSystem
    initCodeEditorSystem ghc
    initCollisionsSystem
    initConstraintSystem
    initControlsSystem vrPal
    initCreatorSystem
    initDragSystem
    initHapticsSystem
    initLifetimeSystem
    initPhysicsSystem
    initPlayPauseSystem
    initProfilerSystem
    initRenderSystem
    initSynthSystem pd
    initSelectionSystem
    initSceneSystem
    initSceneLoaderSystem
    initSceneWatcherSystem
    initSharedSystem
    initTextSystem

    startHandsSystem
    startKeyPadsSystem
    startSceneWatcherSystem

    listToMaybe <$> liftIO getArgs >>= \case
        Nothing -> showSceneLoader
        -- Spawn a new object for quick new object dev work
        Just "new" -> do
            codeInFile <- createNewStartExpr
            void . spawnEntity $ do
                myShape      ==> Cube
                mySize       ==> newEntitySize
                myProperties ==> [Floating]
                myColor      ==> V4 0.1 0.1 0.1 1
                myStartExpr  ==> codeInFile
        Just name -> do
            rumpusRoot <- getRumpusRootFolder
            let scene = rumpusRoot </> name
            sceneExists <- liftIO $ doesDirectoryExist scene
            -- If the name of a scene is given, load it.
            -- Otherwise assume it is the name of a code file.
            if sceneExists
                then loadScene scene
                else do
                    codeInFile <- createStartExpr name
                    void . spawnEntity $ do
                        myShape      ==> Cube
                        mySize       ==> newEntitySize
                        myProperties ==> [Floating]
                        myColor      ==> V4 0.1 0.1 0.1 1
                        myStartExpr  ==> codeInFile

    --when isBeingProfiled loadTestScene


rumpusMain :: IO ()
rumpusMain = withRumpusGHC $ \ghc -> withPd $ \pd -> do
    vrPal <- initVRPal "Rumpus" [UseOpenVR]

    --singleThreadedLoop ghc pd vrPal
    multiThreadedLoop ghc pd vrPal

singleThreadedLoop :: TChan CompilationRequest -> PureData -> VRPal -> IO ()
singleThreadedLoop ghc pd vrPal = do
    void . flip runStateT newECS $ do
        initializeECS ghc pd vrPal
        whileWindow (gpWindow vrPal) $ do
            playerM44 <- viewSystem sysControls ctsPlayer
            (headM44, events) <- tickVR vrPal playerM44
            profile "Controls"  $ tickControlEventsSystem headM44 events
            profile "Rendering" $ tickRenderSystem headM44

            tickLogic

tickLogic :: ECSMonad ()
tickLogic = do
    -- Perform a minor GC to just get the young objects created during the last frame
    -- without traversing all of memory
    --liftIO performMinorGC
    profile "KeyPads"           $ tickKeyPadsSystem
    profile "Clock"             $ tickClockSystem
    profile "CodeEditorInput"   $ tickCodeEditorInputSystem
    profile "CodeEditorResults" $ tickCodeEditorResultsSystem
    profile "Attachment"        $ tickAttachmentSystem
    profile "Constraint"        $ tickConstraintSystem
    profile "Script"            $ tickScriptSystem
    profile "Lifetime"          $ tickLifetimeSystem
    profile "Animation"         $ tickAnimationSystem
    profile "Physics"           $ tickPhysicsSystem
    profile "SyncPhysicsPoses"  $ tickSyncPhysicsPosesSystem
    profile "Collisions"        $ tickCollisionsSystem
    profile "HandControls"      $ tickHandControlsSystem
    profile "Sound"             $ tickSynthSystem
    profile "SceneWatcher"      $ tickSceneWatcherSystem

-- Experiment with running logic on the background thread.
-- Attempts to never stall the render thread,
-- (i.e. it will reuse the last world state and render it from the latest head position)
-- and has logic thread wait until a new device pose has arrived
-- from OpenVR before ticking.
multiThreadedLoop :: TChan CompilationRequest -> PureData -> VRPal -> IO ()
multiThreadedLoop ghc pd vrPal = do
    startingECS   <- execStateT (initializeECS ghc pd vrPal) newECS
    backgroundBox <- liftIO $ newTVarIO Nothing
    mainThreadBox <- liftIO $ newTVarIO startingECS

    -- LOGIC LOOP (BG THREAD)
    _ <- liftIO . forkOS $ do
        makeContextCurrent (Just (gpThreadWindow vrPal))
        void . flip runStateT startingECS . forever $ do
            (headM44, events) <- atomically $ do
                readTVar backgroundBox >>= \case
                    Just something -> do
                        writeTVar backgroundBox Nothing
                        return something
                    Nothing -> retry

            profile "Controls" $ tickControlEventsSystem headM44 events
            tickLogic

            latestECS <- get
            atomically $ do
                writeTVar mainThreadBox $! latestECS

    -- RENDER LOOP (MAIN THREAD)
    whileWindow (gpWindow vrPal) $ do
        latestECS         <- liftIO . atomically $ readTVar mainThreadBox
        (headM44, events) <- flip evalStateT latestECS (do
            playerM44         <- viewSystem sysControls ctsPlayer
            (headM44, events) <- tickVR vrPal playerM44
            -- FIXME: transforms should be calculated on background thread!
            tickRenderSystem headM44
            glFlush -- as per recommendation in openvr.h
            return (headM44, events))
        liftIO . atomically $ do
            pendingEvents <- readTVar backgroundBox >>= \case
                Just (_, pendingEvents) -> return pendingEvents
                Nothing                 -> return []
            writeTVar backgroundBox (Just (headM44, pendingEvents ++ events))
        return ()
