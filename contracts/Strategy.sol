// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {IKashiPair} from "./sushiswap/kashi-lending/interfaces/IKashiPair.sol";
import {
    IBentoBoxV1 as IBentoBox
} from "./sushiswap/bentobox-sdk/contracts/IBentoBoxV1.sol";
import {
    Rebase,
    RebaseLibrary
} from "./boringcrypto/boring-solidity/libraries/BoringRebase.sol";
import {BIERC20} from "./boringcrypto/boring-solidity/interfaces/IERC20.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using RebaseLibrary for Rebase;

    bool internal isOriginal = true;

    IBentoBox public bentoBox;
    IKashiPair public kashiPair;

    uint256 public dustThreshold = 0;

    constructor(
        address _vault,
        address _bentoBox,
        address _kashiPair
    ) public BaseStrategy(_vault) {
        _initializeStrat(_bentoBox, _kashiPair);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _bentoBox,
        address _kashiPair
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_bentoBox, _kashiPair);
    }

    event Cloned(address indexed clone);

    function cloneKashiLender(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _bentoBox,
        address _kashiPair
    ) external returns (address newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _bentoBox,
            _kashiPair
        );

        emit Cloned(newStrategy);
    }

    function _initializeStrat(address _bentoBox, address _kashiPair) internal {
        require(
            address(kashiPair) == address(0),
            "StategyKashiLending: already initialized"
        );
        require(address(IKashiPair(_kashiPair).bentoBox()) == _bentoBox);
        require(address(IKashiPair(_kashiPair).asset()) == address(want));

        bentoBox = IBentoBox(_bentoBox);
        kashiPair = IKashiPair(_kashiPair);

        want.safeApprove(_bentoBox, type(uint256).max);
    }

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyKashiLender(",
                    kashiPair.symbol(),
                    ")"
                )
            );
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 totalShares =
            sharesInBento().add(
                kashiFractionToBentoShares(kashiFraction(), true)
            );

        return balanceOfWant().add(bentoSharesToWant(totalShares, true));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        (, uint256 lastAccrued, ) = kashiPair.accrueInfo();
        if (block.timestamp > lastAccrued) {
            kashiPair.accrue();
        }

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (assets >= debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets.sub(debt);

            uint256 amountToFree = _profit.add(_debtPayment);

            if (amountToFree > 0 && wantBal < amountToFree) {
                liquidatePosition(amountToFree.sub(wantBal));

                uint256 newLoose = balanceOfWant();

                //if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(
                            newLoose.sub(_profit),
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            //serious loss should never happen but if it does lets record it accurately
            _loss = debt.sub(assets);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = balanceOfWant();

        uint256 shares = 0;

        if (wantBalance > dustThreshold) {
            (, shares) = bentoBox.deposit(
                BIERC20(address(want)),
                address(this),
                address(this),
                wantBalance,
                0 // setting this to 0, let's the previous argument determine the deposit size
            );
        }

        uint256 sharesInBento = sharesInBento();

        if (sharesInBento > wantToBentoShares(dustThreshold, false)) {
            bentoBox.transfer(
                BIERC20(address(want)),
                address(this),
                address(kashiPair),
                sharesInBento
            );

            kashiPair.addAsset(address(this), true, sharesInBento);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = balanceOfWant();
        if (_amountNeeded > wantBalance) {
            uint256 amountToFree = _amountNeeded.sub(wantBalance);

            (, uint256 lastAccrued, ) = kashiPair.accrueInfo();
            if (block.timestamp > lastAccrued) {
                // We need to call accrue to accurately calculate totalAssets
                kashiPair.accrue();
            }

            uint256 deposited = estimatedTotalAssets().sub(wantBalance);

            if (deposited < amountToFree) {
                amountToFree = deposited;
            }
            if (amountToFree > 0) {
                uint256 sharesToFree = wantToBentoShares(amountToFree, true);
                uint256 sharesToFreeFromKashi =
                    sharesToFree.sub(
                        bentoBox.balanceOf(
                            BIERC20(address(want)),
                            address(this)
                        )
                    );

                if (sharesToFreeFromKashi > 0) {
                    kashiPair.removeAsset(
                        address(this),
                        bentoSharesToKashiFraction(sharesToFreeFromKashi, true)
                    );
                }

                bentoBox.withdraw(
                    BIERC20(address(want)),
                    address(this),
                    address(this),
                    0,
                    sharesInBento()
                );
            }

            _liquidatedAmount = balanceOfWant();
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        liquidatePosition(type(uint256).max);
        return balanceOfWant();
    }

    // The _newStrategy must support the same kashiPair or bad things will happen
    function prepareMigration(address _newStrategy) internal override {
        kashiPair.transfer(_newStrategy, kashiFraction());
    }

    function setKashiPair(address _newKashiPair) external onlyGovernance {
        require(
            address(IKashiPair(_newKashiPair).bentoBox()) == address(bentoBox),
            "BentoBox does not match"
        );
        require(
            IKashiPair(_newKashiPair).asset() == BIERC20(address(want)),
            "KashiPair asset does not match want"
        );

        uint256 kashiFraction = kashiFraction();

        if (kashiFraction > 0) {
            kashiPair.removeAsset(address(this), kashiFraction);
        }

        kashiPair = IKashiPair(_newKashiPair);

        uint256 sharesInBento = sharesInBento();

        if (sharesInBento > 0) {
            bentoBox.transfer(
                BIERC20(address(want)),
                address(this),
                address(kashiPair),
                sharesInBento
            );

            kashiPair.addAsset(address(this), true, sharesInBento);
        }
    }

    function setDustThreshold(uint256 _newDustThreshold)
        external
        onlyAuthorized
    {
        dustThreshold = _newDustThreshold;
    }

    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function sharesInBento() internal view returns (uint256) {
        return bentoBox.balanceOf(BIERC20(address(want)), address(this));
    }

    function kashiFraction() internal view returns (uint256) {
        return kashiPair.balanceOf(address(this));
    }

    function wantToBentoShares(uint256 wantAmount, bool roundUp)
        internal
        view
        returns (uint256)
    {
        return bentoBox.toShare(BIERC20(address(this)), wantAmount, roundUp);
    }

    function bentoSharesToWant(uint256 bentoShares, bool roundUp)
        internal
        view
        returns (uint256)
    {
        return bentoBox.toAmount(BIERC20(address(this)), bentoShares, roundUp);
    }

    function bentoSharesToKashiFraction(uint256 bentoShares, bool roundUp)
        internal
        view
        returns (uint256 kashiFraction)
    {
        // Adapted from https://github.com/sushiswap/kashi-lending/blob/b6e3521d8628a835935c94a9039cfd192044d66b/contracts/KashiPair.sol#L320-L323
        Rebase memory totalAsset = kashiPair.totalAsset();
        Rebase memory totalBorrow = kashiPair.totalBorrow();
        uint256 totalAssetShare = totalAsset.elastic;
        uint256 allShare =
            uint256(totalAsset.elastic).add(
                wantToBentoShares(totalBorrow.elastic, !roundUp)
            );
        kashiFraction = allShare == 0
            ? bentoShares
            : bentoShares.mul(totalAsset.base).div(allShare);
    }

    function kashiFractionToBentoShares(uint256 kashiFraction, bool roundUp)
        internal
        view
        returns (uint256 bentoShares)
    {
        // Adapted from https://github.com/sushiswap/kashi-lending/blob/b6e3521d8628a835935c94a9039cfd192044d66b/contracts/KashiPair.sol#L351-L353
        Rebase memory totalAsset = kashiPair.totalAsset();
        Rebase memory totalBorrow = kashiPair.totalBorrow();
        uint256 allShare =
            uint256(totalAsset.elastic).add(
                wantToBentoShares(totalBorrow.elastic, roundUp)
            );
        bentoShares = kashiFraction.mul(allShare).div(totalAsset.base);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }
}
