// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SealedBidAuction
 * @author Crypto Coders
 * @notice مزایده پیشنهاد مخفی از نوع First-Price Sealed-Bid با ETH
 *
 * سازوکار:
 * 1. در مرحله Commit، هر شرکت‌کننده یک Hash از پیشنهاد خود ثبت می‌کند
 *    و ETH کافی را به‌عنوان وثیقه ارسال می‌کند.
 * 2. در مرحله Reveal، شرکت‌کننده مبلغ و رمز (Salt) را ارائه می‌کند.
 * 3. قرارداد Hash را دوباره محاسبه و با مقدار ثبت‌شده مقایسه می‌کند.
 * 4. بالاترین پیشنهاد معتبر برنده می‌شود و مبلغ پیشنهاد خودش را می‌پردازد.
 * 5. پس از نهایی شدن مزایده، سایر شرکت‌کنندگان وثیقه خود را پس می‌گیرند
 *    و برنده نیز مازاد وثیقه خود را برداشت می‌کند.
 *
 * نکته حریم خصوصی:
 * Commit-Reveal مبلغ پیشنهاد را در مرحله اول آشکار نمی‌کند؛ اما پس از
 * مرحله Reveal، پیشنهادهای آشکارشده روی بلاکچین عمومی قابل مشاهده‌اند.
 * این روش حریم خصوصی مطلق یا محرمانگی رمزنگاری‌شده دائمی ایجاد نمی‌کند.
 */

contract SealedBidAuction {
    // -----------------------------
    // اطلاعات مزایده و زمان‌بندی
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

    // Hash تعهد هر شرکت‌کننده
    mapping(address => bytes32) public commitments;

    // وثیقه ETH ارسال‌شده توسط هر شرکت‌کننده
    mapping(address => uint256) public deposits;

    // آیا شرکت‌کننده پیشنهاد خود را آشکار کرده است؟
    mapping(address => bool) public revealed;

    // آیا شرکت‌کننده وجه خود را برداشت کرده است؟
    mapping(address => bool) public fundsClaimed;

    // -----------------------------
    // اطلاعات برنده
    // -----------------------------

    uint256 public highestBid;
    address public highestBidder;

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

    event AuctionFinalized(address indexed winner, uint256 winningBid);

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
     * این تابع کمکی دقیقاً همان فرمولی را برمی‌گرداند که برای Commit
     * و بررسی Reveal استفاده می‌شود.
     *
     * پیشنهاددهنده باید amount و salt را خارج از قرارداد نگهداری کند.
     * Salt باید تصادفی و غیرقابل حدس باشد.
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
    // مرحله اول: ثبت پیشنهاد به‌شکل Hash
    // -----------------------------

    /**
     * هر آدرس فقط یک بار می‌تواند تعهد ثبت کند.
     * msg.value وثیقه‌ای است که باید حداقل به اندازه پیشنهاد نهایی باشد.
     *
     * مبلغ واقعی پیشنهاد در این مرحله در قرارداد ثبت نمی‌شود.
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

    /**
     * شرکت‌کننده باید همان مبلغ و Salt زمان Commit را ارائه کند.
     * اگر Hash جدید با Commitment قبلی برابر نباشد، تراکنش رد می‌شود.
     */
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

        // در صورت تساوی، اولین پیشنهاد آشکارشده حفظ می‌شود.
        if (amount > highestBid) {
            highestBid = amount;
            highestBidder = msg.sender;
        }

        emit BidRevealed(msg.sender, amount);
    }

    // -----------------------------
    // نهایی‌سازی مزایده
    // -----------------------------

    function finalizeAuction() external {
        require(block.timestamp >= revealEndTime, "Reveal not ended");
        require(!finalized, "Already finalized");
        require(!canceled, "Auction canceled");

        finalized = true;

        emit AuctionFinalized(highestBidder, highestBid);
    }

    // -----------------------------
    // برداشت وثیقه یا مازاد توسط پیشنهاددهنده
    // -----------------------------

    /**
     * - بازنده: کل وثیقه را دریافت می‌کند.
     * - برنده: وثیقه منهای مبلغ پیشنهاد خودش را دریافت می‌کند.
     *
     * در این مدل، مزایده از نوع First-Price است؛ بنابراین برنده
     * همان مبلغی را می‌پردازد که پیشنهاد داده است.
     */
    function withdrawBidFunds() external noReentrancy {
        require(finalized, "Auction not finalized");
        require(commitments[msg.sender] != bytes32(0), "No commitment");
        require(!fundsClaimed[msg.sender], "Already claimed");

        fundsClaimed[msg.sender] = true;

        uint256 amountToReturn = deposits[msg.sender];

        if (msg.sender == highestBidder) {
            amountToReturn -= highestBid;
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
    // برداشت مبلغ پیشنهاد برنده توسط فروشنده
    // -----------------------------

    function withdrawProceeds()
        external
        onlySeller
        noReentrancy
    {
        require(finalized, "Auction not finalized");
        require(!proceedsClaimed, "Already claimed");

        proceedsClaimed = true;

        uint256 amount = highestBid;

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
     * برای ساده و قابل‌فهم ماندن نسخه آموزشی، فروشنده فقط پیش از ثبت
     * اولین Commitment و قبل از پایان مرحله Commit می‌تواند لغو کند.
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
            finalized,
            canceled
        );
    }
}
