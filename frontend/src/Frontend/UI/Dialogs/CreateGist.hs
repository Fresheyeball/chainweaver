{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE ExtendedDefaultRules  #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RecursiveDo           #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}

-- | Confirmation dialog for creating a GIST allowing setting of name and description.
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.CreateGist
  ( uiCreateGist
  ) where

------------------------------------------------------------------------------
import           Control.Lens
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Reflex
import           Reflex.Dom
------------------------------------------------------------------------------
import           Obelisk.Generated.Static
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Foundation            hiding (Arg)
import           Frontend.ModuleExplorer        (HasModuleExplorerCfg (..),
                                                 TransactionInfo (..), GistMeta (..))
import           Frontend.UI.DeploymentSettings
import           Frontend.UI.Modal
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.Helpers (imgWithAltCls)
------------------------------------------------------------------------------

type HasUICreateGistModelCfg mConf t =
  ( Monoid mConf, Flattenable mConf t, HasModuleExplorerCfg mConf t
  , HasBackendCfg mConf t
  )


-- | Create a Gist.
--
--   Ask user for name and description for the gist.
uiCreateGist
  :: forall t m a model mConf
  . (MonadWidget t m, HasUICreateGistModelCfg mConf t)
  => model
  -> m (mConf, Event t ())
uiCreateGist ideL = do
  onClose <- modalHeader $ text "Create GitHub Gist"
  modalMain $ do
    (name, desc) <- modalBody $ do
      divClass "segment modal__filler" $ do
        divClass "modal__filler-horizontal-center-box" $
          imgWithAltCls "modal__filler-img" (static @"img/Octocat.jpg") "Github logo" blank
        divClass "group" $ do
          fileName <- labeledTextInputWithDefault "File Name" "pact-web-share.pact"
          description <- labeledTextInputWithDefault "Description" "Pact shared with pact-web."
          pure (fileName, description)

    modalFooter $ do
      onCancel <- cancelButton def "Cancel"
      text " "
      let isDisabled = T.null . T.strip <$> name
      onConfirm <- confirmButton (def & uiButtonCfg_disabled .~ isDisabled) "Create"

      -- TODO: Use `backendCfg_deployCode` instead.
      let
        payload = current $ GistMeta <$> name <*> desc
        cfg = mempty & moduleExplorerCfg_createGist .~ tag payload onConfirm
      pure (cfg, leftmost [onClose, onCancel, onConfirm])


-- | Take label test and default value and produce a labeled input.
labeledTextInputWithDefault
  :: (MonadHold t m, DomBuilder t m, PostBuild t m, MonadFix m)
  => Text
  -> Text
  -> m (Dynamic t Text)
labeledTextInputWithDefault name defVal = mdo
  val <- holdDyn defVal $ onInput
  onInput <- mkLabeledInput uiInputElement name val
  pure val

