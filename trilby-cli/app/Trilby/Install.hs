{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

module Trilby.Install where

import Control.Applicative (empty)
import Control.Monad
import Control.Monad.Extra (fromMaybeM, whenM)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Functor ((<&>))
import Data.List qualified
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Language.Haskell.TH qualified as TH
import System.Posix (getFileStatus)
import Text.Read (readMaybe)
import Trilby.Config (Edition (..))
import Trilby.Options
import Trilby.Util
import Turtle (ExitCode (ExitSuccess))
import Turtle.Prelude hiding (shell, shells)
import Prelude hiding (error)

getDisk :: (MonadIO m) => m Text
getDisk = do
    disk <- prompt "Choose installation disk:"
    diskStatus <- liftIO $ getFileStatus $ Text.unpack disk
    if isBlockDevice diskStatus
        then pure disk
        else do
            error $ "Cannot find disk: " <> disk
            getDisk

getEdition :: (MonadIO m) => m Edition
getEdition =
    fromMaybeM (error "Unknown edition" >> getEdition) $
        readMaybe . Text.unpack <$> prompt "Choose edition:"

getOpts :: (MonadIO m) => InstallOpts Maybe -> InstallOpts m
getOpts opts = do
    InstallOpts
        { efi = maybe (ask "Use EFI boot?" True) pure opts.efi
        , luks = maybe (ask "Encrypt the disk with LUKS2?" True) pure opts.luks
        , luksPassword = maybe (prompt "Choose LUKS password:") pure opts.luksPassword
        , disk = maybe getDisk pure opts.disk
        , format = maybe (ask "Format the disk?" True) pure opts.format
        , edition = maybe getEdition pure opts.edition
        , hostname = maybe (prompt "Choose hostname:") pure opts.hostname
        , username = maybe (prompt "Choose admin username:") pure opts.username
        , reboot = maybe (ask "Reboot system?" True) pure opts.reboot
        }

efiLabel :: Text
efiLabel = "EFI"

luksLabel :: Text
luksLabel = "LUKS"

trilbyLabel :: Text
trilbyLabel = "Trilby"

luksDevice :: Text
luksDevice = "/dev/disk/by-partlabel/" <> luksLabel

luksName :: Text
luksName = "cryptroot"

luksOpenDevice :: Text
luksOpenDevice = "/dev/mapper/" <> luksName

trilbyDevice :: Text
trilbyDevice = "/dev/disk/by-partlabel/" <> trilbyLabel

efiDevice :: Text
efiDevice = "/dev/disk/by-partlabel/" <> efiLabel

rootMount :: Text
rootMount = "/mnt"

rootVol :: Text
rootVol = rootMount <> "/root"

bootVol :: Text
bootVol = rootMount <> "/boot"

homeVol :: Text
homeVol = rootMount <> "/home"

nixVol :: Text
nixVol = rootMount <> "/nix"

trilbyDir :: Text
trilbyDir = rootMount <> "/etc/trilby"

luksPasswordFile :: Text
luksPasswordFile = "/tmp/luksPassword"

flakeTemplate :: Text
flakeTemplate = $(TH.stringE . Text.unpack <=< TH.runIO . Text.readFile $ "assets/install/flake.nix")

hostTemplate :: Text
hostTemplate = $(TH.stringE . Text.unpack <=< TH.runIO . Text.readFile $ "assets/install/host.nix")

userTemplate :: Text
userTemplate = $(TH.stringE . Text.unpack <=< TH.runIO . Text.readFile $ "assets/install/user.nix")

applySubstitutions :: [(Text, Text)] -> Text -> Text
applySubstitutions = flip $ Data.List.foldr $ uncurry Text.replace

install :: (MonadIO m) => InstallOpts Maybe -> m ()
install (getOpts -> opts) = do
    whenM opts.format $ doFormat opts
    rootIsMounted <- shell ("sudo mountpoint -q " <> rootMount) stdin <&> (== ExitSuccess)
    unless rootIsMounted $ errorExit "/mnt is not a mountpoint"
    sudo $ "mkdir -p " <> trilbyDir
    sudo $ "chown -R 1000:1000 " <> trilbyDir
    cd $ fromText trilbyDir
    hostname <- opts.hostname
    username <- opts.username
    edition <- opts.edition
    let hostDir = "hosts/" <> hostname
    let userDir = "users/" <> username
    shells ("mkdir -p " <> hostDir <> " " <> userDir) empty
    let
        substitute :: Text -> Text
        substitute =
            applySubstitutions
                [ ("$hostname", hostname)
                , ("$username", username)
                , ("$edition", tshow edition)
                , ("$channel", "unstable")
                ]
    output "flake.nix" $ toLines $ pure $ substitute flakeTemplate
    output (fromText $ hostDir <> "/default.nix") $ toLines $ pure $ substitute hostTemplate
    output (fromText $ userDir <> "/default.nix") $ toLines $ pure $ substitute userTemplate
    output (fromText $ hostDir <> "/hardware-configuration.nix") $
        inshell ("sudo nixos-generate-config --show-hardware-config --root " <> rootMount) stdin
    sudo $ "nixos-install --flake " <> trilbyDir <> "#" <> hostname <> " --no-root-password"
    whenM opts.reboot $ sudo "reboot"

doFormat :: (MonadIO m) => InstallOpts m -> m ()
doFormat opts = do
    disk <- opts.disk
    sudo $ "sgdisk --zap-all -o " <> disk
    efi <- opts.efi
    when efi do
        sudo $
            Text.unwords
                [ "sgdisk"
                , "-n 1:0:+1G"
                , "-t 1:EF00"
                , "-c 1:" <> efiLabel <> " " <> disk
                ]
    luks <- opts.luks
    let rootPartNum = if efi then 2 else 1
    let rootLabel = if luks then luksLabel else trilbyLabel
    sudo $
        Text.unwords
            [ "sgdisk"
            , "-n " <> tshow rootPartNum <> ":0:0"
            , "-t " <> tshow rootPartNum <> ":8300"
            , "-c " <> tshow rootPartNum <> ":" <> rootLabel
            , disk
            ]
    sudo "partprobe"
    when efi do
        sudo $ "mkfs.fat -F32 -n" <> efiLabel <> " " <> efiDevice
    when luks do
        output (fromText luksPasswordFile) . toLines . pure =<< opts.luksPassword
        sudo $ "cryptsetup luksFormat --type luks2 -d " <> luksPasswordFile <> " " <> luksDevice
        sudo $ "cryptsetup luksOpen -d " <> luksPasswordFile <> " " <> luksDevice <> " " <> luksName
        rm $ fromText luksPasswordFile
    let rootDevice = if luks then luksOpenDevice else trilbyDevice
    sudo $ "mkfs.btrfs -f -L " <> trilbyLabel <> " " <> rootDevice
    sudo "partprobe"
    sudo $ "mount " <> rootDevice <> " " <> rootMount
    sudo $ "btrfs subvolume create " <> rootVol
    sudo $ "btrfs subvolume create " <> homeVol
    sudo $ "btrfs subvolume create " <> nixVol
    unless efi do
        sudo $ "btrfs subvolume create " <> bootVol
    sudo $ "umount " <> rootMount
    sudo $ "mount -o subvol=root,ssd,compress=zstd,noatime " <> rootDevice <> " " <> rootMount
    sudo $ "mkdir -p " <> Text.unwords [bootVol, homeVol, nixVol]
    if efi
        then sudo $ "mount " <> efiDevice <> " " <> bootVol
        else sudo $ "mount -o subvol=boot " <> rootDevice <> " " <> bootVol
    sudo $ "mount -o subvol=home,ssd,compress=zstd " <> rootDevice <> " " <> homeVol
    sudo $ "mount -o subvol=nix,ssd,compress=zstd,noatime " <> rootDevice <> " " <> nixVol
