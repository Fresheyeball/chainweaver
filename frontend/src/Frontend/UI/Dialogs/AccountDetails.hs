{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RecursiveDo #-}
-- | Dialog for viewing the details of an account.
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.AccountDetails
  ( uiAccountDetails
  ) where
------------------------------------------------------------------------------
import           Control.Lens
import           Data.Text (Text)
import qualified Data.IntMap as IntMap
import qualified Pact.Types.ChainId as Pact
import           Reflex
import           Reflex.Dom
------------------------------------------------------------------------------
import           Frontend.KadenaAddress (textKadenaAddress)
------------------------------------------------------------------------------
import           Frontend.UI.Modal
import           Frontend.Wallet
import           Frontend.Crypto.Ed25519 (keyToText)
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.Helpers (dialogSectionHeading)
import           Frontend.Foundation
------------------------------------------------------------------------------

type HasUiAccountDetailsModelCfg mConf key t =
  ( Monoid mConf
  , Flattenable mConf t
  , HasWalletCfg mConf key t
  )

uiAccountDetails
  :: ( HasUiAccountDetailsModelCfg mConf key t
     , MonadWidget t m
     )
  => IntMap.Key
  -> Account key
  -> Event t ()
  -> m (mConf, Event t ())
uiAccountDetails key a _onCloseExternal = mdo
  onClose <- modalHeader $ dynText title

  dwf <- workflow (uiAccountDetailsDetails key a onClose)

  let (title, (conf, dEvent)) = fmap splitDynPure $ splitDynPure dwf

  mConf <- flatten =<< tagOnPostBuild conf

  return ( mConf
         , leftmost [switch $ current dEvent, onClose]
         )

uiAccountDetailsDetails
  :: ( HasUiAccountDetailsModelCfg mConf key t
     , MonadWidget t m
     )
  => IntMap.Key
  -> Account key
  -> Event t ()
  -> Workflow t m (Text, (mConf, Event t ()))
uiAccountDetailsDetails key a onClose = Workflow $ do
  let kAddr = textKadenaAddress $ accountToKadenaAddress a (_account_chainId a)

  let displayText lbl v cls =
        let
          attrFn cfg = uiInputElement $ cfg
            & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
        in
          mkLabeledInputView False lbl attrFn $ pure v

  notesEdit <- divClass "modal__main account-details" $ do
    dialogSectionHeading mempty "Info"
    divClass "group" $ do
      -- Account name
      _ <- displayText "Account Name" (unAccountName (_account_name a)) "account-details__name"
      -- Public key
      _ <- displayText "Public Key" (keyToText . _keyPair_publicKey $ _account_key a) "account-details__pubkey"
      -- Chain id
      _ <- displayText "Chain ID" (Pact._chainId $ _account_chainId a) "account-details__chain-id"
      -- separator
      horizontalDashedSeparator
      -- Notes edit
      notesEdit0 <- fmap value $ mkLabeledClsInput False "Notes" $ \cls -> uiInputElement $ def
        & inputElementConfig_initialValue .~ unAccountNotes (_account_notes a)
        & initialAttributes . at "class" %~ pure . maybe (renderClass cls) (mappend (" " <> renderClass cls))
      -- separator
      horizontalDashedSeparator
      -- Kadena Address
      _ <- displayText "Kadena Address" kAddr "account-details__kadena-address"
      -- copy
      _ <- divClass "account-details__copy-btn-wrapper" $ copyButton (def
        & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
        & uiButtonCfg_title .~ constDyn (Just "Copy")
        ) $ pure kAddr
      pure notesEdit0

  modalFooter $ do
    onRemove <- cancelButton (def & uiButtonCfg_class <>~ " account-details__remove-account-btn") "Remove Account"
    onDone <- confirmButton def "Done"

    let
      onNotesUpdate = (key,) . mkAccountNotes <$> current notesEdit <@ onDone
      conf = mempty & walletCfg_updateAccountNotes .~ onNotesUpdate

    pure ( ("Account Details", (conf, leftmost [onClose, onDone]))
         , uiDeleteConfirmation key onClose <$ onRemove
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
uiDeleteConfirmation thisKey onClose = Workflow $ do
  modalMain $ do
    divClass "segment modal__filler" $ do
      dialogSectionHeading mempty "Warning"

      divClass "group" $
        text "You are about to remove this account from view in your wallet"
      divClass "group" $
        text "The only way to recover any balance in this account will be by restoring the complete wallet with your recovery phrase"
      divClass "group" $
       text "Ensure that you have a backup of account data before removing."

  modalFooter $ do
    onConfirm <- confirmButton (def & uiButtonCfg_class .~ "account-delete__confirm") "Permanently Remove Account"
    let cfg = mempty & walletCfg_delKey .~ (thisKey <$ onConfirm)
    pure ( ("Remove Confirmation", (cfg, leftmost [onClose, onConfirm]))
         , never
         )
