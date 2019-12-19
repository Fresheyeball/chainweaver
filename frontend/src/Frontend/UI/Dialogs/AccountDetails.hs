{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RecursiveDo #-}
-- | Dialog for viewing the details of an account.
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.AccountDetails
  ( uiAccountDetails
  , uiAccountDetailsPublicInfo
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
  modalMain $ divClass "modal__main account-details" $ do
    elClass "h2" "heading heading_type_h2" $ text "Info"
    uiAccountDetailsPublicInfo a

  modalFooter $ do
    onRemove <- cancelButton (def & uiButtonCfg_class <>~ " account-details__remove-account-btn") "Remove Account"
    onDone <- confirmButton def "Done"

    pure ( ("Account Details", (mempty, leftmost [onClose, onDone]))
         , uiDeleteConfirmation key onClose <$ onRemove
         )

uiAccountDetailsPublicInfo
  :: ( MonadWidget t m
     )
  => Account key
  -> m ()
uiAccountDetailsPublicInfo a = do
  let kAddr = textKadenaAddress $ accountToKadenaAddress a
      key = keyToText . _keyPair_publicKey $ _account_key a
      accountName = unAccountName (_account_name a)
  let displayText lbl v cls =
        let
          attrFn cfg = uiInputElement $ cfg
            & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
        in
          mkLabeledInputView False lbl attrFn $ pure v

  divClass "group" $ do
    -- Chain id
    _ <- displayText "Chain ID" (Pact._chainId $ _account_chainId a) "account-details__chain-id"
    -- Account name
    _ <- displayText "Account Name" accountName "account-details__name"
    _ <- divClass "account-details__copy-btn-wrapper" $ copyButton (def
      & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
      & uiButtonCfg_title .~ constDyn (Just "Copy Account Name")
      ) $ pure accountName
    -- Public key
    _ <- displayText "Public Key" key "account-details__pubkey"
    _ <- divClass "account-details__copy-btn-wrapper" $ copyButton (def
      & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
      & uiButtonCfg_title .~ constDyn (Just "Copy Public Key")
      ) $ pure key
    -- Kadena Address
    _ <- displayText "Kadena Address (for use with other Chainweaver wallets)" kAddr "account-details__kadena-address"
    _ <- divClass "account-details__copy-btn-wrapper" $ copyButton (def
      & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
      & uiButtonCfg_title .~ constDyn (Just "Copy Kadena Address")
      ) $ pure kAddr

    pure ()

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
      elClass "h2" "heading heading_type_h2" $ text "Warning"

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
