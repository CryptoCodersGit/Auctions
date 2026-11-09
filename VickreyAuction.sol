// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VickreyAuction
 * @author Crypto Coders
 * @notice مزایده ویکری (Second-Price Sealed-Bid Auction) با ETH
 *
 * سازوکار:
 * 1. شرکت‌کنندگان در مرحله Commit، Hash پیشنهاد خود را همراه وثیقه ثبت می‌کنند.
 * 2. در مرحله Reveal، مبلغ و Salt را آشکار می‌کنند.
 * 3. بالاترین پیشنهاد برنده می‌شود.
 * 4. برنده به‌جای مبلغ پیشنهاد خودش، مبلغ دومین پیشنهاد بالاتر را می‌پردازد.
 * 5. پس از نهایی‌سازی، هر پیشنهاددهنده وثیقه قابل بازگشت خود را برداشت می‌کند.
 *
 * قاعده تساوی:
 * اگر چند پیشنهاد برابر با بالاترین مبلغ وجود داشته باشد، اولین پیشنهاد
 * آشکارشده به‌عنوان برنده باقی می‌ماند و قیمت پرداختی برابر همان مبلغ
 * بالاترین پیشنهاد خواهد بود؛ چون پیشنهاد دوم نیز برابر آن است.
 *
 * نکته مهم:
 * Commit-Reveal باعث می‌شود مبلغ در مرحله ثبت Hash آشکار نشود؛ اما در
 * مرحله Reveal پیشنهادها عمومی می‌شوند. این قرارداد حریم خصوصی دائمی
 * یا محرمانگی رمزنگاری‌شده پس از Reveal فراهم نمی‌کند.
 */

contract VickreyAuction {
    // -----------------------------
    // اطلاعات و زمان‌بندی مزایده
    // -----------------------------

    address payable public seller;

    uint256 public commitEndTime;
    uint256 public revealEndTime;

    bool public finalized;
    bool public canceled;
    bool public proceedsClaimed;
    bool public hasCommitments;

    // -----------------------------
    // اطلاعات پیشنهاددهندگان
    // -----------------------------

    mapping(address => bytes32) public commitments;
    mapping(address => uint256) public deposits;
    mapping(address => bool) public revealed;
    mapping(address => bool) public fundsClaimed;

    // -----------------------------
    // اطلاعات دو پیشنهاد برتر
    // -----------------------------

    uint256 public highestBid;
    address public highestBidder;

    uint256 public secondHighestBid;

    // مبلغی که برنده باید پرداخت کند
    uint256 public clearingPrice;

    // محافظ Reentrancy
    bool private locked;

    // -----------------------------
    // رویدادها
    // -----------------------------

    event AuctionCreated(
        address indexed seller,
        uint256 commitEndTime,
        uint256 revealEndTime
    );

    event BidCommitted(address indexed bidder, bytes32 commitment);

    event BidRevealed(address indexed bidder, uint256 amount);

    event AuctionFinalized(
        address indexed winner,
        uint256 highestBid,
        uint256 secondHighestBid,
        uint256 clearingPrice
    );

    event BidFundsWithdrawn(address indexed bidder, uint256 amount);

    event SellerPaid(address indexed seller, uint256 amount);

    event AuctionCanceled();

    // -----------------------------
    // Modifierها
    // -----------------------------

    modifier onlySeller() {
        require(msg.sender == seller, "Only seller");
        _;
    }

    modifier noReentrancy() {
        require(!locked, "Reentrancy");
        locked = true;
        _;
        locked = false;
    }

    // -----------------------------
    // سازنده
    // -----------------------------

    /**
     * @param _commitDuration مدت مرحله ثبت Hash برحسب ثانیه
     * @param _revealDuration مدت مرحله آشکارسازی پیشنهاد برحسب ثانیه
     */
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration
    ) {
        require(_commitDuration > 0, "Commit duration is zero");
        require(_revealDuration > 0, "Reveal duration is zero");

        seller = payable(msg.sender);

        commitEndTime = block.timestamp + _commitDuration;
        revealEndTime = commitEndTime + _revealDuration;

        emit AuctionCreated(seller, commitEndTime, revealEndTime);
    }

    // -----------------------------
    // ساخت Hash پیشنهاد
    // -----------------------------

    /**
     * برای هر پیشنهاد، یک Salt محرمانه و غیرقابل حدس انتخاب کنید.
     * amount و salt را تا زمان Reveal نزد خود نگه دارید.
     *
     * در Remix می‌توانید از یک مقدار bytes32 مانند یک رشته ۶۴ رقمی
     * هگزادسیمال استفاده کنید.
     */
    function getCommitmentHash(
        uint256 amount,
        bytes32 salt,
        address bidder
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                bidder,
                amount,
                salt
            )
        );
    }

    // -----------------------------
    // مرحله اول: ثبت پیشنهاد مخفی
    // -----------------------------

    /**
     * هر شرکت‌کننده فقط یک Commitment ثبت می‌کند.
     * وثیقه ارسالی باید حداقل به اندازه مبلغی باشد که بعداً آشکار می‌کند.
     */
    function commitBid(bytes32 commitment) external payable {
        require(block.timestamp < commitEndTime, "Commit phase ended");
        require(!canceled, "Auction canceled");
        require(msg.sender != seller, "Seller cannot bid");
        require(commitments[msg.sender] == bytes32(0), "Already committed");
        require(commitment != bytes32(0), "Invalid commitment");
        require(msg.value > 0, "Deposit required");

        commitments[msg.sender] = commitment;
        deposits[msg.sender] = msg.value;
        hasCommitments = true;

        emit BidCommitted(msg.sender, commitment);
    }

    // -----------------------------
    // مرحله دوم: آشکارسازی پیشنهاد
    // -----------------------------

    function revealBid(
        uint256 amount,
        bytes32 salt
    ) external {
        require(block.timestamp >= commitEndTime, "Reveal not started");
        require(block.timestamp < revealEndTime, "Reveal phase ended");
        require(!canceled, "Auction canceled");

        bytes32 commitment = commitments[msg.sender];

        require(commitment != bytes32(0), "No commitment");
        require(!revealed[msg.sender], "Already revealed");
        require(amount > 0, "Bid is zero");
        require(amount <= deposits[msg.sender], "Deposit too small");

        bytes32 calculatedHash = getCommitmentHash(
            amount,
            salt,
            msg.sender
        );

        require(calculatedHash == commitment, "Invalid reveal");

        revealed[msg.sender] = true;

        // اگر پیشنهاد جدید از بالاترین بیشتر باشد:
        // بالاترین قبلی به رتبه دوم منتقل می‌شود.
        if (amount > highestBid) {
            secondHighestBid = highestBid;
            highestBid = amount;
            highestBidder = msg.sender;
        }
        // اگر پیشنهاد جدید بالاتر از رتبه دوم باشد،
        // اما از بالاترین بیشتر نباشد، رتبه دوم به‌روزرسانی می‌شود.
        else if (amount > secondHighestBid) {
            secondHighestBid = amount;
        }

        emit BidRevealed(msg.sender, amount);
    }

    // -----------------------------
    // نهایی‌سازی و تعیین قیمت پرداخت
    // -----------------------------

    /**
     * در مزایده ویکری:
     * برنده = بالاترین پیشنهاددهنده
     * مبلغ پرداختی = دومین پیشنهاد بالاتر
     *
     * اگر فقط یک پیشنهاد معتبر آشکار شده باشد، secondHighestBid صفر است؛
     * بنابراین در این نسخه آموزشی، برنده مبلغ صفر پرداخت می‌کند.
     * در مدل‌های تجاری می‌توان قیمت رزرو تعریف کرد.
     */
    function finalizeAuction() external {
        require(block.timestamp >= revealEndTime, "Reveal not ended");
        require(!finalized, "Already finalized");
        require(!canceled, "Auction canceled");

        finalized = true;
        clearingPrice = secondHighestBid;

        emit AuctionFinalized(
            highestBidder,
            highestBid,
            secondHighestBid,
            clearingPrice
        );
    }

    // -----------------------------
    // برداشت وثیقه یا مازاد پیشنهاددهنده
    // -----------------------------

    /**
     * بازنده: کل وثیقه خود را دریافت می‌کند.
     * برنده: وثیقه منهای clearingPrice را دریافت می‌کند.
     *
     * clearingPrice مبلغی است که به فروشنده تعلق می‌گیرد.
     */
    function withdrawBidFunds() external noReentrancy {
        require(finalized, "Auction not finalized");
        require(commitments[msg.sender] != bytes32(0), "No commitment");
        require(!fundsClaimed[msg.sender], "Already claimed");

        fundsClaimed[msg.sender] = true;

        uint256 amountToReturn = deposits[msg.sender];

        if (msg.sender == highestBidder) {
            amountToReturn -= clearingPrice;
        }

        if (amountToReturn > 0) {
            (bool success, ) = payable(msg.sender).call{
                value: amountToReturn
            }("");

            require(success, "Refund failed");
        }

        emit BidFundsWithdrawn(msg.sender, amountToReturn);
    }

    // -----------------------------
    // برداشت قیمت نهایی توسط فروشنده
    // -----------------------------

    function withdrawProceeds()
        external
        onlySeller
        noReentrancy
    {
        require(finalized, "Auction not finalized");
        require(!proceedsClaimed, "Already claimed");

        proceedsClaimed = true;

        uint256 amount = clearingPrice;

        if (amount > 0) {
            (bool success, ) = seller.call{value: amount}("");
            require(success, "Payment failed");
        }

        emit SellerPaid(seller, amount);
    }

    // -----------------------------
    // لغو مزایده
    // -----------------------------

    /**
     * لغو فقط قبل از پایان مرحله Commit و قبل از دریافت هرگونه وثیقه
     * امکان‌پذیر است.
     */
    function cancelAuction() external onlySeller {
        require(!finalized, "Already finalized");
        require(!canceled, "Already canceled");
        require(block.timestamp < commitEndTime, "Commit phase ended");
        require(!hasCommitments, "Cannot cancel after commitments");

        canceled = true;

        emit AuctionCanceled();
    }

    // -----------------------------
    // اطلاعات کمکی
    // -----------------------------

    function getPhase() external view returns (uint8) {
        if (canceled) return 4;
        if (finalized) return 3;
        if (block.timestamp < commitEndTime) return 1;
        if (block.timestamp < revealEndTime) return 2;
        return 3;
    }

    function getAuctionInfo()
        external
        view
        returns (
            address auctionSeller,
            uint256 commitDeadline,
            uint256 revealDeadline,
            uint256 currentHighestBid,
            address currentWinner,
            uint256 currentSecondHighestBid,
            uint256 finalPrice,
            bool auctionFinalized,
            bool auctionCanceled
        )
    {
        return (
            seller,
            commitEndTime,
            revealEndTime,
            highestBid,
            highestBidder,
            secondHighestBid,
            clearingPrice,
            finalized,
            canceled
        );
    }
}
