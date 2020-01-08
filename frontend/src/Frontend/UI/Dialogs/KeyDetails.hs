{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ConstraintKinds #-}
-- | Dialog for viewing the details of a key.
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.KeyDetails
  ( uiKeyDetails
  ) where
 
------------------------------------------------------------------------------
import           Control.Lens
import           Data.Text (Text)
import qualified Data.IntMap as IntMap

------------------------------------------------------------------------------
import           Reflex
import           Reflex.Dom hiding (Key)
------------------------------------------------------------------------------
import           Frontend.UI.Modal
import           Frontend.Wallet
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.Helpers (dialogSectionHeading)
import           Frontend.Foundation
------------------------------------------------------------------------------

type HasUiKeyDetailsModelCfg mConf key t =
  ( Monoid mConf
  , Flattenable mConf t
  , HasWalletCfg mConf key t
  )

uiKeyDetails
  :: ( HasUiKeyDetailsModelCfg mConf key t
     , MonadWidget t m
     )
  => IntMap.Key
  -> Key key
  -> Event t ()
  -> m (mConf, Event t ())
uiKeyDetails keyIndex key onCloseExternal = mdo
  onClose <- modalHeader $ dynText title
  dwf <- workflow (uiKeyDetailsDetails keyIndex key onClose onCloseExternal)
  let (title, (conf, dEvent)) = fmap splitDynPure $ splitDynPure dwf
  mConf <- flatten =<< tagOnPostBuild conf
  return ( mConf
         , leftmost [switch $ current dEvent, onClose]
         )

uiKeyDetailsDetails
  :: ( HasUiKeyDetailsModelCfg mConf key t
     , MonadWidget t m
     )
  => IntMap.Key
  -> Key key
  -> Event t ()
  -> Event t ()
  -> Workflow t m (Text, (mConf, Event t ()))
uiKeyDetailsDetails keyIndex key onClose onCloseExternal = Workflow $ do
  let displayText lbl v cls =
        let
          attrFn cfg = uiInputElement $ cfg
            & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
        in
          mkLabeledInputView False lbl attrFn $ pure v

  notesEdit <- divClass "modal__main key-details" $ do
    divClass "group" $ do
      -- Public key
      _ <- displayText "Public Key" (keyToText $ _keyPair_publicKey $ _key_pair key) "key-details__pubkey"
      -- Notes edit
      fmap value $ mkLabeledClsInput False "Notes" $ \cls -> uiInputElement $ def
        & inputElementConfig_initialValue .~ unAccountNotes (_key_notes key)
        & initialAttributes . at "class" %~ pure . maybe (renderClass cls) (mappend (" " <> renderClass cls))

  modalFooter $ do
    onRemove <- cancelButton (def & uiButtonCfg_class <>~ " account-details__remove-account-btn") "Remove Key"
    onDone <- confirmButton def "Done"

    let done = leftmost [onClose, onDone]
        conf = mempty & walletCfg_updateKeyNotes .~ attachWith (\t _ -> (keyIndex, mkAccountNotes t)) (current notesEdit) (done <> onCloseExternal)

    pure ( ("Key Details", (conf, done))
         , uiDeleteConfirmation keyIndex onClose <$ onRemove
         )

uiDeleteConfirmation
  :: forall key t m mConf
  . ( MonadWidget t m
    , Monoid mConf
    , HasWalletCfg mConf key t
    )
  => IntMap.Key
  -> Event t ()
  -> Workflow t m (Text, (mConf, Event t ()))
uiDeleteConfirmation key onClose = Workflow $ do
  modalMain $ do
    divClass "segment modal__filler" $ do
      dialogSectionHeading mempty "Warning"

      divClass "group" $
        text "You are about to remove this key from view in your wallet"
      divClass "group" $
        text "The only way to recover any balance in this key will be by restoring the complete wallet with your recovery phrase"
      divClass "group" $
       text "Ensure that you have a backup of wallet data before removing."

  modalFooter $ do
    onConfirm <- confirmButton (def & uiButtonCfg_class .~ "account-delete__confirm") "Permanently Remove Key"
    let cfg = mempty & walletCfg_delKey .~ (key <$ onConfirm)
    pure ( ("Remove Confirmation", (cfg, leftmost [onClose, onConfirm]))
         , never
         )
