// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TaskNetwork is ReentrancyGuard {
    // USDC token contract (6 decimals)
    IERC20 public immutable usdc;

    // Struct for task submission
    struct TaskSubmission {
        address user; // Submitter
        uint256 taskId; // Task type (e.g., 1 = Washing Dishes)
        string beforePhoto; // IPFS hash of before photo
        string afterPhoto; // IPFS hash of after photo
        uint256 stake; // USDC staked (6 decimals, e.g., 1000000 = 1 USDC)
        bool completed; // Whether validated as complete
        uint256 submissionTime; // Timestamp of submission
        uint256 validatorCount; // Number of validators
        address[] validators; // List of validators
        mapping(address => bool) validatorVotes; // Validator votes (true = approve)
        bool rewarded; // Whether reward has been paid
        uint256 submissionAttempts; // Number of attempts for this submission
        uint256 dailySubmissionCount; // Submissions made today
        uint256 lastSubmissionDay; // Last day submitted
    }

    // Struct for task type
    struct Task {
        string name; // e.g., "Washing Dishes"
        uint256 totalStake; // Total USDC staked for submissions
        uint256 rewardPool; // USDC available for rewards
        uint256 submissionCount; // Number of submissions
    }

    // Struct for validator pricing
    struct ValidatorPricing {
        uint256 validatorCount; // Current number of active validators
        uint256 baseReward; // Base validator reward (in USDC, 6 decimals)
        uint256 lastUpdate; // Last time pricing was updated
    }

    // Task and submission data
    mapping(uint256 => Task) public tasks; // taskId => Task
    mapping(uint256 => mapping(uint256 => TaskSubmission)) public submissions; // taskId => submissionId => TaskSubmission
    mapping(address => uint256[]) public userSubmissions; // User's submission IDs
    mapping(address => mapping(uint256 => uint256)) public dailySubmissions; // user => day => count
    mapping(uint256 => ValidatorPricing) public validatorPricing; // taskId => ValidatorPricing

    // Constants
    uint256 public constant MAX_VALIDATORS = 5; // Max validators per submission
    uint256 public constant MIN_VALIDATORS = 3; // Min validators to finalize
    uint256 public constant MAX_DAILY_SUBMISSIONS = 3; // Max resubmissions per day
    uint256 public constant CUTOFF_HOUR_5PM_EST = 17 * 3600; // 5 PM EST in seconds
    uint256 public constant PAYOUT_HOUR_8PM_EST = 20 * 3600; // 8 PM EST in seconds
    uint256 public constant ONE_HOUR = 3600; // Seconds in an hour
    uint256 public constant ONE_DAY = 24 * 3600; // Seconds in a day
    uint256 public constant BASE_VALIDATOR_REWARD = 100000; // 0.1 USDC (6 decimals)
    uint256 public constant MINIMUM_REWARD = 100000; // 0.1 USDC (6 decimals)
    uint256 public constant POOL_FUNDING_PERCENT = 10; // 10% of approved stakes to reward pool
    uint256 public constant REWARD_PRECISION = 1e18; // Precision for calculations
    uint256 public constant WEIGHT_EXPONENT = 11; // For stake^1.1 (11/10)

    // Events
    event TaskCreated(uint256 indexed taskId, string name);
    event TaskSubmitted(address indexed user, uint256 indexed taskId, uint256 submissionId, string beforePhoto, string afterPhoto, uint256 stake);
    event TaskValidated(address indexed validator, uint256 indexed taskId, uint256 submissionId, bool approved);
    event RewardsDistributed(uint256 indexed taskId, uint256 submissionId, address indexed user, uint256 userReward, uint256 validatorReward);
    event ValidatorPricingUpdated(uint256 indexed taskId, uint256 newReward, uint256 validatorCount);
    event StakeRefunded(address indexed user, uint256 indexed taskId, uint256 submissionId, uint256 stake);
    event RewardPoolFunded(uint256 indexed taskId, uint256 amount);

    // Constructor
    // This constructor is for example purposes, tasks should come from msg.sender
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        // Initialize tasks
        tasks[1] = Task("Washing Dishes", 0, 0, 0);
        tasks[2] = Task("Taking Out Trash", 0, 0, 0);
        tasks[3] = Task("Sweeping", 0, 0, 0);
        emit TaskCreated(1, "Washing Dishes");
        emit TaskCreated(2, "Taking Out Trash");
        emit TaskCreated(3, "Sweeping");

        // Initialize validator pricing
        for (uint256 i = 1; i <= 3; i++) {
            validatorPricing[i] = ValidatorPricing(0, BASE_VALIDATOR_REWARD, block.timestamp);
        }
    }

    // Modifier to check task exists
    modifier taskExists(uint256 taskId) {
        require(bytes(tasks[taskId].name).length > 0, "Task does not exist");
        _;
    }

    // Function to submit a task
    function submitTask(
        uint256 taskId,
        string memory beforePhoto,
        string memory afterPhoto,
        uint256 stake
    ) public taskExists(taskId) nonReentrant {
        require(stake > 0, "Stake must be greater than 0");
        require(usdc.allowance(msg.sender, address(this)) >= stake, "Insufficient allowance");

        uint256 currentDay = block.timestamp / ONE_DAY;
        if (dailySubmissions[msg.sender][currentDay] >= MAX_DAILY_SUBMISSIONS) {
            revert("Max daily submissions reached");
        }

        // Transfer stake
        require(usdc.transferFrom(msg.sender, address(this), stake), "USDC transfer failed");

        // Update daily submission count
        dailySubmissions[msg.sender][currentDay]++;
        uint256 submissionId = tasks[taskId].submissionCount;
        TaskSubmission storage submission = submissions[taskId][submissionId];
        submission.user = msg.sender;
        submission.taskId = taskId;
        submission.beforePhoto = beforePhoto;
        submission.afterPhoto = afterPhoto;
        submission.stake = stake;
        submission.completed = false;
        submission.submissionTime = block.timestamp;
        submission.validatorCount = 0;
        submission.rewarded = false;
        submission.submissionAttempts = 1;
        submission.dailySubmissionCount = dailySubmissions[msg.sender][currentDay];
        submission.lastSubmissionDay = currentDay;

        tasks[taskId].totalStake += stake;
        tasks[taskId].submissionCount += 1;
        userSubmissions[msg.sender].push(submissionId);

        emit TaskSubmitted(msg.sender, taskId, submissionId, beforePhoto, afterPhoto, stake);
    }

    // Function to resubmit a denied task
    function resubmitTask(uint256 taskId, uint256 submissionId, string memory newBeforePhoto, string memory newAfterPhoto) public taskExists(taskId) nonReentrant {
        TaskSubmission storage submission = submissions[taskId][submissionId];
        require(submission.user == msg.sender, "Not your submission");
        require(submission.completed && submission.stake > 0, "Submission not denied or already refunded");
        require(submission.submissionAttempts < MAX_DAILY_SUBMISSIONS, "Max resubmissions reached");

        uint256 currentDay = block.timestamp / ONE_DAY;
        require(submission.lastSubmissionDay == currentDay, "Can only resubmit same day");
        if (dailySubmissions[msg.sender][currentDay] >= MAX_DAILY_SUBMISSIONS) {
            revert("Max daily submissions reached");
        }

        // Update submission
        submission.beforePhoto = newBeforePhoto;
        submission.afterPhoto = newAfterPhoto;
        submission.completed = false;
        submission.validatorCount = 0;
        submission.submissionTime = block.timestamp;
        submission.submissionAttempts += 1;
        submission.dailySubmissionCount = dailySubmissions[msg.sender][currentDay] + 1;
        delete submission.validators;

        dailySubmissions[msg.sender][currentDay]++;

        emit TaskSubmitted(msg.sender, taskId, submissionId, newBeforePhoto, newAfterPhoto, submission.stake);
    }

    // Function to refund stake early
    function refundStake(uint256 taskId, uint256 submissionId) public taskExists(taskId) nonReentrant {
        TaskSubmission storage submission = submissions[taskId][submissionId];
        require(submission.user == msg.sender, "Not your submission");
        require(submission.stake > 0, "No stake to refund");
        require(!submission.rewarded, "Already rewarded");

        uint256 stake = submission.stake;
        submission.stake = 0;
        submission.completed = true;
        tasks[taskId].totalStake -= stake;

        require(usdc.transfer(msg.sender, stake), "Refund failed");
        emit StakeRefunded(msg.sender, taskId, submissionId, stake);
    }

    // Function to validate a submission
    function validateTask(uint256 taskId, uint256 submissionId, bool approve) public taskExists(taskId) nonReentrant {
        TaskSubmission storage submission = submissions[taskId][submissionId];
        require(submission.user != address(0), "Submission does not exist");
        require(!submission.completed, "Submission already completed");
        require(submission.user != msg.sender, "Cannot validate own submission");
        require(submission.validatorCount < MAX_VALIDATORS, "Max validators reached");
        require(!submission.validatorVotes[msg.sender], "Already validated");

        updateValidatorPricing(taskId);

        submission.validators.push(msg.sender);
        submission.validatorVotes[msg.sender] = approve;
        submission.validatorCount += 1;

        validatorPricing[taskId].validatorCount += 1;

        emit TaskValidated(msg.sender, taskId, submissionId, approve);

        if (submission.validatorCount >= MIN_VALIDATORS) {
            processValidation(taskId, submissionId);
        }
    }

    // Internal function to process validation
    function processValidation(uint256 taskId, uint256 submissionId) internal {
        TaskSubmission storage submission = submissions[taskId][submissionId];
        uint256 approveCount = 0;

        for (uint256 i = 0; i < submission.validatorCount; i++) {
            if (submission.validatorVotes[submission.validators[i]]) {
                approveCount++;
            }
        }

        if (approveCount > submission.validatorCount / 2) {
            submission.completed = true; // Approved, eligible for reward
        } else {
            submission.completed = true; // Denied, can resubmit
            if (submission.submissionAttempts >= MAX_DAILY_SUBMISSIONS) {
                uint256 stake = submission.stake;
                submission.stake = 0;
                tasks[taskId].totalStake -= stake;
                require(usdc.transfer(submission.user, stake), "Auto-refunded failed");
                emit StakeRefunded(submission.user, taskId, submissionId, stake);
            }
        }
    }

    // Function to update validator pricing hourly
    function updateValidatorPricing(uint256 taskId) public taskExists(taskId) {
        ValidatorPricing storage pricing = validatorPricing[taskId];
        if (block.timestamp >= pricing.lastUpdate + ONE_HOUR) {
            uint256 newReward = BASE_VALIDATOR_REWARD * 10 / (10 + pricing.validatorCount);
            if (newReward < BASE_VALIDATOR_REWARD / 2) newReward = BASE_VALIDATOR_REWARD / 2;
            if (newReward > BASE_VALIDATOR_REWARD * 2) newReward = BASE_VALIDATOR_REWARD * 2;

            pricing.baseReward = newReward;
            pricing.lastUpdate = block.timestamp;

            emit ValidatorPricingUpdated(taskId, newReward, pricing.validatorCount);
        }
    }

    // Internal function to calculate total weighted stake and approved submissions
    function calculateWeightedStake(uint256 taskId) internal view returns (uint256 totalWeightedStake, uint256[] memory approvedSubmissions, uint256 approvedCount) {
        uint256 submissionCount = tasks[taskId].submissionCount;
        approvedSubmissions = new uint256[](submissionCount);
        totalWeightedStake = 0;
        approvedCount = 0;

        for (uint256 submissionId = 0; submissionId < submissionCount; submissionId++) {
            TaskSubmission storage submission = submissions[taskId][submissionId];
            if (submission.completed && !submission.rewarded && submission.stake > 0 && isEligibleForPayout(submission.submissionTime)) {
                uint256 weightedStake = (submission.stake * REWARD_PRECISION) / 10;
                weightedStake = (weightedStake * 11) / 10; // stake * 1.1
                totalWeightedStake += weightedStake;
                approvedSubmissions[approvedCount] = submissionId;
                approvedCount++;
            }
        }
    }

    // Internal function to process payout for a single submission
    function processSubmissionPayout(
        uint256 taskId,
        uint256 submissionId,
        uint256 totalWeightedStake,
        uint256 availablePool
    ) internal {
        TaskSubmission storage submission = submissions[taskId][submissionId];
        submission.rewarded = true;

        // Calculate user reward: (stake^1.1 / totalWeightedStake) * rewardPool
        uint256 weightedStake = (submission.stake * REWARD_PRECISION) / 10;
        weightedStake = (weightedStake * 11) / 10; // stake * 1.1
        uint256 userReward = totalWeightedStake > 0
            ? (weightedStake * availablePool) / totalWeightedStake
            : 0;

        // Apply minimum reward
        if (availablePool > 0 && userReward < MINIMUM_REWARD) {
            userReward = MINIMUM_REWARD;
        }

        // Fund pool with 10% of stake
        uint256 poolContribution = (submission.stake * POOL_FUNDING_PERCENT) / 100;
        tasks[taskId].rewardPool += poolContribution;
        emit RewardPoolFunded(taskId, poolContribution);

        // Refund stake (minus pool contribution)
        uint256 stakeToRefund = submission.stake - poolContribution;
        if (stakeToRefund > 0) {
            require(usdc.transfer(submission.user, stakeToRefund), "Stake refund failed");
        }

        // Pay user reward
        if (userReward > 0) {
            require(tasks[taskId].rewardPool >= userReward, "Insufficient reward pool");
            require(usdc.transfer(submission.user, userReward), "User reward transfer failed");
            tasks[taskId].rewardPool -= userReward;
        }

        // Pay validators
        uint256 validatorReward = validatorPricing[taskId].baseReward;
        for (uint256 j = 0; j < submission.validatorCount; j++) {
            address validator = submission.validators[j];
            if (submission.validatorVotes[validator]) {
                require(tasks[taskId].rewardPool >= validatorReward, "Insufficient reward pool");
                require(usdc.transfer(validator, validatorReward), "Validator reward transfer failed");
                tasks[taskId].rewardPool -= validatorReward;
            }
        }

        tasks[taskId].totalStake -= submission.stake;
        submission.stake = 0;

        emit RewardsDistributed(taskId, submissionId, submission.user, userReward, validatorReward);
    }

    // Function to distribute rewards (called daily at 8 PM EST)
    function distributeRewards(uint256 taskId) public taskExists(taskId) nonReentrant {
        uint256 currentTime = block.timestamp % ONE_DAY;
        require(currentTime >= PAYOUT_HOUR_8PM_EST && currentTime < PAYOUT_HOUR_8PM_EST + ONE_HOUR, "Only at 8 PM EST");

        // Calculate total weighted stake and approved submissions
        (uint256 totalWeightedStake, uint256[] memory approvedSubmissions, uint256 approvedCount) = calculateWeightedStake(taskId);

        // Distribute rewards for each approved submission
        uint256 availablePool = tasks[taskId].rewardPool;
        for (uint256 i = 0; i < approvedCount; i++) {
            processSubmissionPayout(taskId, approvedSubmissions[i], totalWeightedStake, availablePool);
        }
    }

    // Internal function to check payout eligibility
    function isEligibleForPayout(uint256 submissionTime) internal view returns (bool) {
        uint256 submissionDay = submissionTime / ONE_DAY;
        uint256 submissionTimeOfDay = submissionTime % ONE_DAY;
        uint256 currentDay = block.timestamp / ONE_DAY;

        return submissionTimeOfDay <= CUTOFF_HOUR_5PM_EST && submissionDay <= currentDay;
    }

    // Function to estimate potential reward
    function estimateReward(uint256 taskId, uint256 stake) public view taskExists(taskId) returns (uint256 estimatedReward, uint256 percentage) {
        uint256 currentPool = tasks[taskId].rewardPool;
        uint256 totalWeightedStake = 0;
        uint256 weightedStake = (stake * REWARD_PRECISION) / 10;
        weightedStake = (weightedStake * 11) / 10; // stake * 1.1

        // Calculate total weighted stake for approved submissions
        for (uint256 submissionId = 0; submissionId < tasks[taskId].submissionCount; submissionId++) {
            TaskSubmission storage submission = submissions[taskId][submissionId];
            if (submission.completed && !submission.rewarded && submission.stake > 0 && isEligibleForPayout(submission.submissionTime)) {
                uint256 submissionWeightedStake = (submission.stake * REWARD_PRECISION) / 10;
                submissionWeightedStake = (submissionWeightedStake * 11) / 10;
                totalWeightedStake += submissionWeightedStake;
            }
        }

        // Include the hypothetical stake
        totalWeightedStake += weightedStake;

        // Estimate reward
        estimatedReward = totalWeightedStake > 0
            ? (weightedStake * currentPool) / totalWeightedStake
            : 0;
        if (currentPool > 0 && estimatedReward < MINIMUM_REWARD) {
            estimatedReward = MINIMUM_REWARD;
        }

        // Calculate percentage (scaled to 1e18 for precision)
        percentage = totalWeightedStake > 0
            ? (weightedStake * REWARD_PRECISION) / totalWeightedStake
            : 0;

        return (estimatedReward, percentage);
    }

    // View functions
    function getTask(uint256 taskId) public view taskExists(taskId) returns (string memory name, uint256 totalStake, uint256 rewardPool, uint256 submissionCount) {
        Task memory task = tasks[taskId];
        return (task.name, task.totalStake, task.rewardPool, task.submissionCount);
    }

    function getSubmission(uint256 taskId, uint256 submissionId) public view taskExists(taskId) returns (
        address user,
        string memory beforePhoto,
        string memory afterPhoto,
        uint256 stake,
        bool completed,
        uint256 validatorCount,
        bool rewarded,
        uint256 submissionAttempts,
        uint256 dailySubmissionCount
    ) {
        TaskSubmission storage submission = submissions[taskId][submissionId];
        return (
            submission.user,
            submission.beforePhoto,
            submission.afterPhoto,
            submission.stake,
            submission.completed,
            submission.validatorCount,
            submission.rewarded,
            submission.submissionAttempts,
            submission.dailySubmissionCount
        );
    }

    function getValidatorPricing(uint256 taskId) public view taskExists(taskId) returns (uint256 validatorCount, uint256 baseReward, uint256 lastUpdate) {
        ValidatorPricing memory pricing = validatorPricing[taskId];
        return (pricing.validatorCount, pricing.baseReward, pricing.lastUpdate);
    }
}
