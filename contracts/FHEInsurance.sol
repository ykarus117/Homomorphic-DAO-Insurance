// SPDX-License-Identifier: GPL-3.0-or-later
// Author: Gregorio Colucci
pragma solidity ^0.8.26;
import {
    FHE,
    ebool,
    externalEbool,
    euint32,
    euint64,
    euint8,
    externalEuint32,
    externalEuint64
} from "@fhevm/solidity/lib/FHE.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

// TODO: the following code is missing almost all over/under flow checks
interface votable {
    function StartVote(address from, euint64 risk, function(bool) external _callback) external;
    function DecryptRisk(euint64 risk) external returns (uint64);
    function CastVote(address to, externalEbool vote, bytes calldata voteProof) external;
    function PublicReveal(address toReveal) external;
    event VoteStart(address from, euint64 risk);
    error DuplicateRequest(address sender);
    error NotFound(address sender);
}

contract Vote is votable, ZamaEthereumConfig {
    struct request {
        function(bool) external _callback;
        euint32 votes;
        euint32 totalVotes;
        uint256 expiration;
        ebool result;
        bool exists;
    }

    mapping(address => request) private requestingUsers;
    mapping(address => euint64) private voters;

    function StartVote(address from, euint64 risk, function(bool) external _callback) external override {
        require(!requestingUsers[from].exists, DuplicateRequest(from));
        requestingUsers[from] = request({
            _callback: _callback,
            exists: true,
            votes: FHE.asEuint32(0),
            totalVotes: FHE.asEuint32(0),
            result: FHE.asEbool(false),
            expiration: block.timestamp + 1 minutes
        });

        FHE.allowThis(risk);
        FHE.allowThis(requestingUsers[from].result);
        emit VoteStart(from, risk);
    }

    function CastVote(address to, externalEbool vote, bytes calldata voteProof) external override {
        require(requestingUsers[to].exists, NotFound(msg.sender));
        ebool castedVote = FHE.fromExternal(vote, voteProof);
        // Aye votes +1, nay +0
        requestingUsers[to].votes = FHE.select(
            castedVote,
            FHE.add(requestingUsers[to].votes, 1),
            FHE.add(requestingUsers[to].votes, 0)
        );
        requestingUsers[to].totalVotes = FHE.add(requestingUsers[to].totalVotes, 1);
    }

    function PublicReveal(address toReveal) external override {
        require(requestingUsers[toReveal].exists, NotFound(msg.sender));

        // The vote window must be expired
        require(requestingUsers[toReveal].expiration < block.timestamp);

        euint32 majority = FHE.div(requestingUsers[toReveal].totalVotes, 2);
        requestingUsers[toReveal].result = FHE.gt(requestingUsers[toReveal].votes, majority);
        FHE.makePubliclyDecryptable(requestingUsers[toReveal].result);
    }

    function DecryptRisk(euint64 risk) external override returns (uint64) {}
}

contract Insurance is ZamaEthereumConfig {
    euint64 private _totalSupply;
    string _name;
    string _uri;
    string _symbol;
    address private _vote;
    address private _owner;
    bool _isInit;

    struct User {
        insuredUser user;
        bool exists;
    }

    struct insuredUser {
        address beneficiary;
        euint64 amount; // insured amount
        euint64 expectedPremium; // monthly premium
        uint256 lastTimeStamp;
        uint8 missedDeposits;
    }

    struct u {
        euint64 wallet;
        bool exists;
    }

    error UnauthorizedUser(address sender);
    error DoubleInit(address sender);
    error IncorrectAmount(address sender);
    error TooEarlyDeposit(address sender);
    error DeadlineMissed(address sender);
    error AmountNotReleased(address sender);
    error NotEnoughSupply(address sender);
    error UserNotFound(address sender);

    event UserRegistred(address user);
    event UserEvaluation(address user, bytes32 premium);

    mapping(address => User) insuredUsers; // users with an active insurance their amount it unusable and unknown
    mapping(address => u) users; // usable amount

    constructor(string memory name, string memory symbol, string memory uri, address vote) {
        _name = name;
        _symbol = symbol;
        _uri = uri;
        _vote = vote;
        _owner = msg.sender;
    }

    function Init() external {
        require(msg.sender == _owner, UnauthorizedUser(msg.sender));
        require(!_isInit, DoubleInit(msg.sender));
        _totalSupply = FHE.asEuint64(100000);
        FHE.allowThis(_totalSupply);
        _isInit = true;
    }

    // Very simplified Generalized linear model for client risk calculation

    // log(risk) = log(b_0) + log(b_1) * age + log(b_2) * gender + log(b_3) * healthIndex + log(365)

    // exp(risk) is the mortality probability within the year for the given data, all data is scaled (10e6)
    function _GLM(externalEuint64[] memory params, bytes[] calldata inputProof) private returns (euint64) {
        uint24[3] memory w = [975321, 3112073, 1005482];
        // log(b_0) + log(365)
        euint64 risk = FHE.asEuint64(168615735 + 58998974);

        for (uint8 i = 0; i < 3; i++) {
            euint64 encryptedEuint64 = FHE.fromExternal(params[i], inputProof[i]);
            euint64 param = FHE.mul(encryptedEuint64, uint24(w[i]));
            risk = FHE.add(risk, param);
        }

        FHE.allowThis(risk);
        FHE.makePubliclyDecryptable(risk);

        return risk;
    }

    // returns the calculated premium from the requested coverage amount, and duration of the policy
    // life = true means a lifelong policy
    // premium = risk * coverage * ((duration/100)^life + (1/10)^life) with life = [0,1] (scaled)
    function _premium(euint64 risk, euint64 coverage, euint64 duration, ebool life) private returns (euint64) {
        euint64 coverageS = FHE.mul(coverage, 10e6);
        euint64 coverageW = FHE.mul(coverageS, risk);
        euint64 durationS = FHE.mul(duration, 10e5);
        return FHE.select(life, FHE.mul(coverageW, 10e4), FHE.add(coverageW, durationS));
    }

    // returns the handle of the calculated premium to the user.
    // params: age      gender     health     insured amount, duration, life true/false
    function Evaluation(
        externalEuint64[] calldata params,
        bytes[] calldata proofs,
        externalEbool life,
        bytes calldata lifeProof
    ) external {
        euint64 evaluation = _evaluation(params, proofs, life, lifeProof);
        FHE.allow(evaluation, msg.sender);
        FHE.allowThis(evaluation);
        emit UserEvaluation(msg.sender, euint64.unwrap(evaluation));
    }

    function _evaluation(
        externalEuint64[] calldata params,
        bytes[] calldata proofs,
        externalEbool life,
        bytes calldata lifeProof
    ) private returns (euint64) {
        require(params.length == 5 && proofs.length == 5, "Wrong argument(s) len");
        euint64 risk = _GLM(params, proofs);

        euint64 requiredAmount = FHE.fromExternal(params[3], proofs[3]);
        euint64 policyDuration = FHE.fromExternal(params[4], proofs[4]);
        ebool isLife = FHE.fromExternal(life, lifeProof);
        return _premium(risk, requiredAmount, policyDuration, isLife);
    }

    function RegisterInsuredUser(euint64 premium, euint64 amount, address beneficiary) public {
        // register the insured user
        insuredUsers[msg.sender] = User({
            exists: true,
            user: insuredUser({
                beneficiary: beneficiary,
                amount: amount,
                expectedPremium: premium,
                lastTimeStamp: block.timestamp + 4 weeks,
                missedDeposits: 0
            })
        });

        emit UserRegistred(msg.sender);

        // Create beneficiary account (empty)
        users[beneficiary].wallet = FHE.asEuint64(0);
        users[beneficiary].exists = true;
    }

    function depositMonthly(externalEuint64 ex, bytes calldata inputProof) public {
        // Only registred users can deposit on the token
        User memory currentUser = insuredUsers[msg.sender];
        require(currentUser.exists, UnauthorizedUser(msg.sender));

        bool early = currentUser.user.lastTimeStamp + 4 weeks >= block.timestamp;
        bool missedPayments = currentUser.user.missedDeposits < 5;

        // enforce no more than 1 payment per month and no more than 5 times late payments
        require(early, TooEarlyDeposit(msg.sender));
        require(missedPayments, DeadlineMissed(msg.sender));

        if (!early) {
            currentUser.user.missedDeposits += 1;
        }

        euint64 sent = FHE.fromExternal(ex, inputProof);

        // Check if the given amount is equal to the expected
        euint64 amount_temp = FHE.add(_totalSupply, sent);
        euint64 amount_temp_0 = FHE.add(_totalSupply, 0);

        ebool choice = FHE.eq(currentUser.user.expectedPremium, sent);

        _totalSupply = FHE.select(choice, amount_temp, amount_temp_0);

        currentUser.user.lastTimeStamp = block.timestamp;
    }

    function ClaimIssue(address dUser) public {
        User memory currentUser = insuredUsers[dUser];

        // asses users existance
        require(currentUser.exists, UnauthorizedUser(msg.sender));
        // is the requireing user a valid beneficiary?
        require(currentUser.user.beneficiary == msg.sender, UnauthorizedUser(msg.sender));

        // transfer from the insured user to the beneficiary
        users[msg.sender].wallet = currentUser.user.amount;

        // Allow beneficiary rights to the insured user amount' handle
        FHE.allow(users[msg.sender].wallet, msg.sender);
        delete insuredUsers[dUser];
    }

    /* TODO
    function TransferToPlain(address to, externalEuint64 n, bytes calldata inputproof) public {
        require(users[msg.sender].exists, UserNotFound(msg.sender));
        IERC20 destination = IERC20(to);
        euint64 to_transfer = FHE.fromExternal(n, inputproof);
        users[msg.sender].wallet = FHE.sub(_totalSupply, to_transfer);
        FHE.allowThisTransient(to_transfer);
        FHE.makePubliclyDecryptable(to_transfer);
        destination.transfer()
    }
    */
}
