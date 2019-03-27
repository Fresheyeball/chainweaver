{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE ExtendedDefaultRules   #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE QuasiQuotes            #-}
{-# LANGUAGE RecursiveDo            #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}

-- | Implementation of the Frontend.ModuleExplorer interface.
--
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
--

module Frontend.ModuleExplorer.Impl
  ( -- * Interface
    module API
    -- * Types
  , HasModuleExplorerModelCfg
    -- * Creation
  , makeModuleExplorer
  ) where

------------------------------------------------------------------------------
import           Control.Lens
import           Control.Monad             (guard, (<=<))
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import qualified Data.Map                  as Map
import           Data.Text                 (Text)
import           Reflex
import           Reflex.Dom.Core           (HasJSContext, MonadHold, PostBuild)
import           Safe                      (tailSafe)
------------------------------------------------------------------------------
import           Pact.Types.Lang
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Editor
import           Frontend.Foundation
import           Frontend.JsonData
import           Frontend.Messages
import           Frontend.ModuleExplorer   as API
import           Frontend.Repl
import           Frontend.Storage

type HasModuleExplorerModelCfg mConf t =
  ( Monoid mConf
  , HasEditorCfg mConf t
  , HasMessagesCfg mConf t
  , HasJsonDataCfg mConf t
  , HasReplCfg mConf t
  , HasBackendCfg mConf t
  )

type HasModuleExplorerModel model t =
  ( HasEditor model t
  , HasJsonData model t
  , HasBackend model t
  )


-- | Constraints needed by functions in this module.
type ReflexConstraints t m =
  ( MonadHold t m, TriggerEvent t m, Reflex t, PerformEvent t m
  , HasJSContext (Performable m) , MonadJSM (Performable m)
  , PostBuild t m, MonadFix m
  )

-- Storing data:

-- | Storage keys for referencing data to be stored/retrieved.
data StoreModuleExplorer a where
  StoreModuleExplorer_SessionFile  :: StoreModuleExplorer Text -- Current editor contents
  -- TODO: Store `moduleExplorer_loaded` too with this key:
  {- StoreModuleExplorer_SessionFileRef :: StoreModuleExplorer ModuleSource -}

deriving instance Show (StoreModuleExplorer a)

-- | Write text to localstorage.
storeEditor :: MonadJSM m => Text -> m ()
storeEditor ks = setItemLocal StoreModuleExplorer_SessionFile ks

-- | Load text from localstorage.
loadEditor :: MonadJSM m => m (Maybe Text)
loadEditor = getItemLocal StoreModuleExplorer_SessionFile


makeModuleExplorer
  :: forall t m cfg mConf model
  . ( ReflexConstraints t m
    , HasModuleExplorerCfg cfg t
    {- , HasModuleExplorerModel model t -}
    , HasModuleExplorerModelCfg mConf t
    , HasModuleExplorerModel model t
    , MonadSample t (Performable m)
    , MonadJSM m
    )
  => model
  -> cfg
  -> m (mConf, ModuleExplorer t)
makeModuleExplorer m cfg = mfix $ \ ~(_, explr) -> do
    selectedFile <- selectFile
      (fmapMaybe getFileModuleRef $ cfg ^. moduleExplorerCfg_pushModule)
      (leftmost
        [cfg ^. moduleExplorerCfg_selectFile
        , Nothing <$ cfg ^. moduleExplorerCfg_goHome
        ]
      )

    onPostBuild <- getPostBuild
    mInitFile <- loadEditor
    let
      onInitFile =
        if isNothing mInitFile
           then (const $ FileRef_Example ExampleRef_Verification) <$> onPostBuild
           else never
      editorInitCfg = mempty
        & editorCfg_loadCode .~ fmapMaybe (const mInitFile) onPostBuild
    -- Store to disk max every 2 seconds:
    onStore <- throttle 2 $ updated $ m ^. editor_code
    performEvent_ $ storeEditor <$> onStore

    (lFileCfg, loadedSource) <- loadToEditor m
      (leftmost [cfg ^. moduleExplorerCfg_loadFile, onInitFile])
      (cfg ^. moduleExplorerCfg_loadModule)

    (stckCfg, stack) <- pushPopModule m explr
      (cfg ^. moduleExplorerCfg_goHome)
      (cfg ^. moduleExplorerCfg_pushModule)
      (cfg ^. moduleExplorerCfg_popModule)

    let
      deployEdCfg = deployEditor m $ cfg ^. moduleExplorerCfg_deployEditor
      deployCodeCfg = deployCode m $ cfg ^. moduleExplorerCfg_deployCode

    growth <- mkSelectionGrowth explr

    modules <- makeModuleList m (cfg ^. moduleExplorerCfg_modules)

    pure
      ( mconcat [ editorInitCfg, lFileCfg, stckCfg, deployEdCfg, deployCodeCfg ]
      , ModuleExplorer
        { _moduleExplorer_moduleStack = stack
        , _moduleExplorer_selectedFile = selectedFile
        , _moduleExplorer_loaded = loadedSource
        , _moduleExplorer_selectionGrowth = growth
        , _moduleExplorer_modules = modules
        }
      )

-- | Check whether we are going deeper with selections or not.
mkSelectionGrowth
  :: (Reflex t, MonadHold t m, PerformEvent t m, TriggerEvent t m
     , MonadIO (Performable m)
     , HasModuleExplorer explr t
     )
  => explr
  -> m (Dynamic t Ordering)
mkSelectionGrowth explr = do
    let
      stk = explr ^. moduleExplorer_moduleStack
      stkLen = length <$> stk

    let
      sel = explr ^. moduleExplorer_selectedFile
      stkLenSel = zipDyn stkLen sel

    let
      onGrowth = pushAlways (\(newLen, newSel) -> do
          oldLen <- sample $ current stkLen
          oldSel <- sample $ current sel
          pure $ case (newLen `compare` oldLen, newSel `compareSel` oldSel) of
            (EQ, a) -> a
            (a, EQ) -> a
            (_, a)  -> a -- File wins.
        )
        (updated stkLenSel)
    -- Reset is necessary, otherwise we get animations everytime the module
    -- explorer tab gets selected:
    onReset <- fmap (const EQ) <$> delay 0.6 onGrowth
    holdDyn EQ $ leftmost [onGrowth, onReset]

  where
    compareSel oldSelected newSelected =
      case (oldSelected, newSelected) of
        (Nothing, Nothing) -> EQ
        (Nothing, Just _)  -> LT
        (Just _, Nothing)  -> GT
        (Just _, Just _)   -> EQ


deployEditor
  :: forall t mConf model
  . ( Reflex t
    , HasModuleExplorerModelCfg  mConf t
    , HasModuleExplorerModel model t
    )
  => model
  -> Event t TransactionInfo
  -> mConf
deployEditor m = deployCode m . attach (current $ m ^. editor_code)

deployCode
  :: forall t mConf model
  . ( Reflex t
    , HasModuleExplorerModelCfg  mConf t
    , HasModuleExplorerModel model t
    )
  => model
  -> Event t (Text, TransactionInfo)
  -> mConf
deployCode m onDeploy =
  let
    mkReq :: Dynamic t ((Text, TransactionInfo) -> Maybe BackendRequest)
    mkReq = do
      ed      <- m ^. jsonData_data
      pure $ \(code, info) -> do
        let b = _transactionInfo_backend info
        d <- ed ^? _Right
        pure $ BackendRequest code d b (_transactionInfo_keys info)

    jsonError :: Dynamic t (Maybe Text)
    jsonError = do
      ed <- m ^. jsonData_data
      pure $ case ed of
        Left _  -> Just $ "Deploy not possible: JSON data was invalid!"
        Right _ -> Nothing
  in
    mempty
      & backendCfg_deployCode .~ attachWithMaybe ($) (current mkReq) onDeploy
      & messagesCfg_send .~ tagMaybe (current jsonError) onDeploy

-- | Takes care of loading a file/module into the editor.
loadToEditor
  :: forall m t mConf model
  . ( ReflexConstraints t m
    , HasModuleExplorerModelCfg  mConf t
    , MonadSample t (Performable m)
    , HasBackend model t, HasEditor model t
    )
  => model
  -> Event t FileRef
  -> Event t ModuleRef
  -> m (mConf, MDynamic t LoadedRef)
loadToEditor m onFileRef onModRef = do
    let onFileModRef = fmapMaybe getFileModuleRef onModRef

    onFile <- fetchFile $ leftmost
      [ onFileRef
      , _moduleRef_source <$> onFileModRef
      ]

    (modCfg, onMod)  <- loadModule m $ fmapMaybe getDeployedModuleRef onModRef

    fileModRequested <- holdDyn Nothing $ leftmost
      [ Just <$> onFileModRef
      , Nothing <$ onFileRef -- Order important.
      ]
    let
      onFileMod :: Event t (FileModuleRef, Code)
      onFileMod = fmapMaybe id $
        attachPromptlyDynWith getFileModuleCode fileModRequested onFile

    loaded <- holdDyn Nothing $ leftmost
      [ Just .LoadedRef_Module . (moduleRef_source %~ ModuleSource_File) . fst <$> onFileMod
      , Just. LoadedRef_File . fst <$> onFile -- Order important we prefer `onFileMod` over `onFile`.
      , Just . LoadedRef_Module . (moduleRef_source %~ ModuleSource_Deployed) . fst <$> onMod
        -- For now, until we have file saving support:
      , fmap (const Nothing) . ffilter id . updated $ m ^.editor_modified
      ]

    let
      onCode = fmap _unCode $ leftmost
        [ snd <$> onFileMod
        , snd <$> onFile
        , view codeOfModule . snd <$> onMod
        ]

    pure ( mconcat [modCfg, mempty & editorCfg_loadCode .~ onCode]
         , loaded
         )
  where
    getFileModuleCode :: Maybe FileModuleRef -> (FileRef, PactFile) -> Maybe (FileModuleRef, Code)
    getFileModuleCode = \case
      Nothing -> const Nothing
      Just r@(ModuleRef _ n) ->
        fmap ((r,) . view codeOfModule)
        . Map.lookup n
        . fileModules
        . snd


-- | Select a `PactFile`, note that a file gets also implicitely selected when
--   a module of a given file gets selected.
selectFile
  :: forall m t
  . ( MonadHold t m, PerformEvent t m, MonadJSM (Performable m)
    , TriggerEvent t m, MonadFix m
    )
  => Event t FileModuleRef
  -> Event t (Maybe FileRef)
  -> m (MDynamic t (FileRef, PactFile))
selectFile onModRef onMayFileRef = mdo

    onFileSelect <- fetchFile . push (filterNewFileRef selected) $ leftmost
      [ _moduleRef_source <$> onModRef
      , fmapMaybe id onMayFileRef
      ]

    selected <- holdDyn Nothing $ leftmost
      [ Just    <$> onFileSelect
      , Nothing <$  ffilter isNothing onMayFileRef
      ]
    pure selected
  where
    filterNewFileRef oldFile newFileRef = do
      cOld <- sample . current $ oldFile
      pure $ if fmap fst cOld /= Just newFileRef
         then Just newFileRef
         else Nothing


-- | Push/pop a module on the `_moduleExplorer_moduleStack`.
--
--   The deployed module on the top of the stack will always be kept up2date on
--   `_backend_deployed` fires.
pushPopModule
  :: forall m t mConf model
  . ( MonadHold t m, PerformEvent t m, MonadJSM (Performable m)
    , HasJSContext (Performable m), TriggerEvent t m, MonadFix m, PostBuild t m
    , MonadSample t (Performable m)
    , HasMessagesCfg  mConf t, Monoid mConf
    , HasBackend model t
    )
  => model
  -> ModuleExplorer t
  -> Event t ()
  -> Event t ModuleRef
  -> Event t ()
  -> m (mConf, Dynamic t [(ModuleRef, ModDef)])
pushPopModule m explr onClear onPush onPop = mdo
    let onFileModRef = fmapMaybe getFileModuleRef onPush
    onFileModule <- waitForFile (explr ^. moduleExplorer_selectedFile) onFileModRef

    (lCfg, onDeployedModule) <- loadModule m $ fmapMaybe getDeployedModuleRef onPush

    stack <- holdUniqDyn <=< foldDyn id [] $ leftmost
      [ (:) . (_1 . moduleRef_source %~ ModuleSource_File) <$> onFileModule
      , (:) . (_1 . moduleRef_source %~ ModuleSource_Deployed) <$> onDeployedModule
      , tailSafe <$ onPop
      , const [] <$ onClear
      , updateStack <$> onRefresh
      ]
    (rCfg, onRefresh) <- refreshHead $
      tagPromptlyDyn stack $ leftmost [ onPop, m ^. backend_deployed ]

    pure
      ( lCfg <> rCfg
      , stack
      )
  where
    waitForFile
      :: MDynamic t (FileRef, PactFile)
      -> Event t FileModuleRef
      -> m (Event t (FileModuleRef, ModDef))
    waitForFile fileL onRef = do
      onReset <- delay 0 $ updated fileL
      modReq <- holdDyn Nothing $ leftmost [Just <$> onRef, Nothing <$ onReset]
      let
        retrievedModule = runMaybeT $ do
          cFile <- MaybeT fileL
          cReq <- MaybeT modReq
          guard $ _moduleRef_source cReq == fst cFile

          let n = _moduleRef_name cReq
          moduleL <- MaybeT . pure $ Map.lookup n $ fileModules (snd cFile)
          pure (cReq, moduleL)
      pure $ fmapMaybe id . updated $ retrievedModule

    updateStack :: (ModuleRef, ModuleDef (Term Name)) -> [(ModuleRef, ModuleDef (Term Name))] -> [(ModuleRef, ModuleDef (Term Name))]
    updateStack update = map (doUpdate update)
      where
        doUpdate new@(uK, _) old@(k, _) = if uK == k then new else old

    refreshHead :: Event t [(ModuleRef, ModDef)] -> m (mConf, Event t (ModuleRef, ModDef))
    refreshHead onMods = do
      let getHeadRef = getDeployedModuleRef <=< fmap fst . listToMaybe
      (cfg, onDeployed) <- loadModule m $ fmapMaybe getHeadRef onMods
      pure $ (cfg, (_1 . moduleRef_source %~ ModuleSource_Deployed) <$> onDeployed)


-- | Load a deployed module.
--
--   Loading errors will be reported to `Messages`.
loadModule
  :: forall m t mConf model
  . ( ReflexConstraints t m
    , Monoid mConf, HasMessagesCfg mConf t
    , MonadSample t (Performable m)
    , HasBackend model t
    )
  => model
  -> Event t DeployedModuleRef
  -> m (mConf, Event t (DeployedModuleRef, ModuleDef (Term Name)))
loadModule backendL onRef = do
  onErrModule <- fetchModule backendL onRef
  let
    onErr    = fmapMaybe (^? _2 . _Left) onErrModule
    onModule = fmapMaybe (traverse (^? _Right)) onErrModule
  pure
    ( mempty & messagesCfg_send .~ fmap ("Loading of module failed: " <>) onErr
    , onModule
    )
