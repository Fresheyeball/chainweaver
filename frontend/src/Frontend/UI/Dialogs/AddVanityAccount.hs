{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}
module Frontend.UI.Dialogs.AddVanityAccount
  ( uiAddAccountButton
  , uiCreateAccountButton
  , uiCreateAccountDialog
  ) where

import Data.Aeson (toJSON)
import           Control.Lens                           ((^.),(<>~), (^?), to)
import           Control.Error                          (hush)
import           Control.Monad.Trans.Class              (lift)
import           Control.Monad.Trans.Maybe              (MaybeT (..), runMaybeT)
import           Data.Maybe                             (isNothing)
import           Data.Either                            (isLeft)
import qualified Data.Map as Map
import           Data.Text                              (Text)
import qualified Data.HashMap.Lazy as HM
import qualified Data.Set as Set

import           Kadena.SigningApi

import           Reflex
import           Reflex.Dom.Core

import           Reflex.Network.Extended

import           Frontend.UI.DeploymentSettings
import           Frontend.UI.Dialogs.DeployConfirmation (CanSubmitTransaction, submitTransactionWithFeedback, _Status_Done, transactionSubmitFeedback_listenStatus)
import           Frontend.UI.Dialogs.AddVanityAccount.DefineKeyset (DefinedKeyset, uiDefineKeyset, emptyKeysetPresets)
import           Frontend.UI.Modal.Impl
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.Helpers (dialogSectionHeading)
import           Frontend.UI.Widgets.AccountName (uiAccountNameInput)

import           Frontend.Crypto.Class
import           Frontend.JsonData
import           Frontend.Network
import           Frontend.Wallet
import           Frontend.Foundation
import           Frontend.Log
import           Frontend.TxBuilder

-- Allow the user to create a 'vanity' account, which is an account with a custom name
-- that lives on the chain. Requires GAS to create.

type HasUISigningModelCfg mConf key t =
  ( Monoid mConf
  , Flattenable mConf t
  , HasWalletCfg mConf key t
  , HasJsonDataCfg mConf t
  , HasNetworkCfg mConf t
  )

tempkeyset :: Text
tempkeyset = "temp-vanity-keyset"

mkPactCode :: AccountName -> Text
mkPactCode acc = "(coin.create-account \"" <> unAccountName acc <> "\" (read-keyset \"" <> tempkeyset <> "\"))"

uiAddAccountButton
  :: forall t m key mConf
     . ( MonadWidget t m, Monoid mConf
       , HasModalCfg mConf (ModalImpl m key t) t
       )
  => ModalIde m key t
  -> m mConf
uiAddAccountButton m = do
  eOpenAddAccount <- uiButton (def & uiButtonCfg_class <>~ " main-header__add-account-button")  (text "+ Add Account")
  pure $ mempty & modalCfg_setModal .~ (Just (uiAddAccountDialog m) <$ eOpenAddAccount)

uiAddAccountDialog
  :: ( MonadWidget t m, Monoid mConf
     , HasWalletCfg mConf key t
     )
  => ModalIde m key t
  -> Event t ()
  -> m (mConf, Event t ())
uiAddAccountDialog model _onCloseExternal = mdo
  onClose <- modalHeader $ text "Add Account"
  name <- modalMain $ do
    dialogSectionHeading mempty "Notice"
    divClass "group" $ text "Add an Account here to display its status. If the Account does not yet exist, then you will be able to create and control the Account on the blockchain."
    dialogSectionHeading mempty "Add Account"
    divClass "group" $ do
      uiAccountNameInput model Nothing
  add <- modalFooter $ do
    confirmButton (def & uiButtonCfg_disabled .~ (isNothing <$> name)) "Add Account"
  let val = runMaybeT $ do
        net <- lift $ current $ model ^. network_selectedNetwork
        n <- MaybeT $ current name
        pure (net, n)
      conf = mempty & walletCfg_importAccount .~ tagMaybe val add
  -- Since this always succeeds, we're okay to close on the add button event
  return (conf, onClose <> add)

uiCreateAccountButton :: DomBuilder t m => UiButtonCfg -> m (Event t ())
uiCreateAccountButton cfg =
  uiButton (cfg & uiButtonCfg_class <>~ "button_type_secondary" <> "button_type_secondary") $ do
    elClass "span" "button__text" $ text "+ Create Account"

uiCreateAccountDialog
  :: ( Monoid mConf, Flattenable mConf t
     , MonadWidget t m
     , HasJsonData model t, HasLogger model t, HasNetwork model t, HasWallet model key t
     , HasCrypto key (Performable m)
     , HasJsonDataCfg mConf t, HasNetworkCfg mConf t, HasWalletCfg mConf key t
     , HasTransactionLogger m
     )
  => model
  -> AccountName
  -> ChainId
  -> Maybe PublicKey
  -> Event t ()
  -> m (mConf, Event t ())
uiCreateAccountDialog model name chain mPublicKey _onCloseExternal = do
  rec
    onClose <- modalHeader $ dynText title
    (title, (conf, closes)) <- fmap (fmap splitDynPure . splitDynPure)
      $ workflow $ createAccountSplash model name chain mPublicKey emptyKeysetPresets
  mConf <- flatten =<< tagOnPostBuild conf
  let close = switch $ current closes
  pure (mConf, onClose <> close)

createAccountSplash
  :: ( Monoid mConf, Flattenable mConf t
     , MonadWidget t m
     , HasJsonData model t, HasLogger model t, HasNetwork model t, HasWallet model key t
     , HasCrypto key (Performable m)
     , HasJsonDataCfg mConf t, HasNetworkCfg mConf t, HasWalletCfg mConf key t
     , HasTransactionLogger m
     )
  => model
  -> AccountName
  -> ChainId
  -> Maybe PublicKey
  -> DefinedKeyset t
  -> Workflow t m (Text, (mConf, Event t ()))
createAccountSplash model name chain mPublicKey keysetPresets = Workflow $ do
  (keyset, keysetSelections) <- modalMain $ do
    dialogSectionHeading mempty "Notice"
    -- Placeholder text
    divClass "group" $ text "In order to receive funds to an Account, the unique Account must be recorded on the blockchain. First configure the Account by defining which keys are required to sign transactions. Then create the Account by recording it on the blockchain."
    dialogSectionHeading mempty "Destination"
    divClass "group" $ transactionDisplayNetwork model
    case mPublicKey of
      Nothing -> do
        dialogSectionHeading mempty "Define Account Keyset"
        divClass "group" $ do
          uiDefineKeyset model keysetPresets

      Just key -> do
        dialogSectionHeading mempty "Account Key"
        _ <- divClass "group" $ uiInputElement $ def
          & inputElementConfig_initialValue .~ keyToText key
          & initialAttributes <>~ ("disabled" =: "true" <> "class" =: " key-details__pubkey input labeled-input__input")
        pure $ ( constDyn $ Just $ AddressKeyset
                 { _addressKeyset_keys = Set.singleton key
                 , _addressKeyset_pred = "keys-all"
                 }
               , emptyKeysetPresets
               )
  (cancel, next) <- modalFooter $ do
    cancel <- cancelButton def "Cancel"
    let cfg = def & uiButtonCfg_disabled .~ fmap isNothing keyset
    notGasPayer <- confirmButton cfg "I am not the Gas Payer"
    gasPayer <- confirmButton cfg "I am the Gas Payer"
    let next = leftmost
          [ tagMaybe (fmap (createAccountNotGasPayer model name chain mPublicKey keysetSelections) <$> current keyset) notGasPayer
          , tagMaybe (fmap (createAccountConfig model name chain mPublicKey keysetSelections) <$> current keyset) gasPayer
          ]
    pure (cancel, next)
  return (("Create Account", (mempty, cancel)), next)

createAccountNotGasPayer
  :: ( Monoid mConf
     , Flattenable mConf t
     , HasJsonData model t, HasJsonDataCfg mConf t
     , HasLogger model t
     , HasNetwork model t, HasNetworkCfg mConf t
     , HasWallet model key t, HasWalletCfg mConf key t
     , HasCrypto key (Performable m)
     , MonadWidget t m
     , HasTransactionLogger m
     )
  => model
  -> AccountName
  -> ChainId
  -> Maybe PublicKey
  -> DefinedKeyset t
  -> AddressKeyset
  -> Workflow t m (Text, (mConf, Event t ()))
createAccountNotGasPayer ideL name chain mPublicKey selectedKeyset keyset = Workflow $ do
  modalMain $ do
    dialogSectionHeading mempty "Notice"
    divClass "group" $ text "The text below contains all of the Account info you have just configured. Share this Tx Builder with someone else to pay the gas for the transaction to create the Account."
    dialogSectionHeading mempty "Tx Builder"
    divClass "group" $ do
      _ <- uiDisplayTxBuilderWithCopy False $ TxBuilder
        { _txBuilder_accountName = name
        , _txBuilder_chainId = chain
        , _txBuilder_keyset = Just keyset
        }
      pure ()
  modalFooter $ do
    back <- cancelButton def "Back"
    done <- confirmButton def "Done"

    pure ( ("Create Account", (mempty, done))
        , createAccountSplash ideL name chain mPublicKey selectedKeyset <$ back
        )

createAccountConfig
  :: forall key t m mConf model
  . ( MonadWidget t m
    , HasUISigningModelCfg mConf key t
    , HasCrypto key (Performable m)
    , HasJsonData model t, HasLogger model t, HasNetwork model t, HasWallet model key t
    , HasTransactionLogger m
    )
  => model
  -> AccountName
  -> ChainId
  -> Maybe PublicKey
  -> DefinedKeyset t
  -> AddressKeyset
  -> Workflow t m (Text, (mConf, Event t ()))
createAccountConfig ideL name chainId mPublicKey selectedKeyset keyset = Workflow $ do
  let includePreviewTab = False

  rec
    (curSelection, eNewAccount, _) <- buildDeployTabs customConfigTab includePreviewTab controls

    (conf, result, gasPayer) <- elClass "div" "modal__main transaction_details" $ do
      (cfg, cChainId, mSender, ttl, gasLimit, _, _) <- tabPane mempty curSelection DeploymentSettingsView_Cfg $
        -- Is passing around 'Maybe x' everywhere really a good way of doing this ?
        uiCfg
          Nothing
          ideL
          (predefinedChainIdDisplayed chainId ideL)
          Nothing
          (Just defaultTransactionGasLimit)
          []
          Nothing
          $ uiSenderDropdown def

      mGasPayer <- tabPane mempty curSelection DeploymentSettingsView_Keys $ do
        let onSenderUpdate = gate (current $ isNothing <$> gasPayer) $ updated mSender

        dialogSectionHeading mempty "Gas Payer"
        divClass "group" $ elClass "div" "segment segment_type_tertiary labeled-input" $ do
          divClass "label labeled-input__label" $ text "Account Name"
          let ddCfg = def & dropdownConfig_attributes .~ pure ("class" =: "labeled-input__input")
          uiSenderDropdown ddCfg ideL cChainId onSenderUpdate

      let payload = HM.singleton tempkeyset $ toJSON keyset
          code = mkPactCode name
          deployConfig = DeploymentSettingsConfig
            { _deploymentSettingsConfig_chainId = userChainIdSelect
            , _deploymentSettingsConfig_userTab = Nothing :: Maybe (Text, m ())
            , _deploymentSettingsConfig_code = pure code
            , _deploymentSettingsConfig_sender = uiSenderDropdown def
            , _deploymentSettingsConfig_data = Just payload
            , _deploymentSettingsConfig_nonce = Nothing
            , _deploymentSettingsConfig_ttl = Nothing
            , _deploymentSettingsConfig_gasLimit = Nothing
            , _deploymentSettingsConfig_caps = Nothing
            , _deploymentSettingsConfig_extraSigners = []
            , _deploymentSettingsConfig_includePreviewTab = includePreviewTab
            }

          capabilities = mGasPayer <&>
            maybe mempty (\a -> fst a =: [_dappCap_cap defaultGASCapability])

      pure
        ( cfg & networkCfg_setSender .~ fmapMaybe (fmap unAccountName) (updated mSender)
        , buildDeploymentSettingsResult ideL mSender (fmap fst <$> mGasPayer) (pure mempty) cChainId capabilities ttl gasLimit (pure code) deployConfig
        , mGasPayer
        )

      networkAccounts = ffor2 (ideL ^. wallet_accounts) (ideL ^. network_selectedNetwork) $ \ad n ->
        fromMaybe mempty $ Map.lookup n (unAccountData ad)

      senderKeyPairs = ffor3 networkAccounts (ideL ^. wallet_keys) mGasPayer $
        \accs keys -> foldMap $ getSigningPairs chainId keys accs . Set.singleton

      capabilities = ffor senderKeyPairs $ \kps -> Map.unionsWith (<>) $ ffor kps (=: [_dappCap_cap defaultGASCapability])

      conf = cfg & networkCfg_setSender .~ fmapMaybe (fmap unAccountName) (updated mGasPayer)
      result = buildDeploymentSettingsResult
        ideL
        mGasPayer
        (pure mempty)
        cChainId
        capabilities
        ttl
        gasLimit
        (pure code)
        deployConfig

  let preventProgress = (\r gp -> isLeft r || isNothing gp) <$> result <*> mGasPayer

  modalFooter $ do
    onBack <- cancelButton def "Back"
    onNewAccount <- confirmButton (def & uiButtonCfg_disabled .~ preventProgress) "Create Account"

    command <- performEvent $ tagMaybe (current $ fmap hush result) onNewAccount

    pure ( ("Add New Account", (conf, never))
         , leftmost
           [ attachWith
               (\ns res -> createAccountSubmit ideL (_deploymentSettingsResult_chainId res) res ns)
               (current $ ideL ^. network_selectedNodes)
               command

           , createAccountSplash ideL name chainId mPublicKey selectedKeyset <$ onBack
           ]
         )

createAccountSubmit
  :: forall mConf model key t m a
  .  ( Monoid mConf
     , HasWalletCfg mConf key t
     , CanSubmitTransaction t m
     , HasLogger model t
     , HasTransactionLogger m
     )
  => model
  -> ChainId
  -> DeploymentSettingsResult key
  -> [Either a NodeInfo]
  -> Workflow t m (Text, (mConf, Event t ()))
createAccountSubmit model chainId result nodeInfos = Workflow $ do
  let cmd = _deploymentSettingsResult_command result

  submitFeedback <- elClass "div" "modal__main transaction_details" $
    submitTransactionWithFeedback model cmd chainId nodeInfos

  let succeeded = fmapMaybe (^? _Status_Done) (submitFeedback ^. transactionSubmitFeedback_listenStatus . to updated)

  done <- modalFooter $ confirmButton def "Done"

  pure
    ( ("Creating Account",
      ( mempty & walletCfg_refreshBalances <>~ succeeded
      , done
      ))
    , never
    )
