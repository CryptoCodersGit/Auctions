// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DutchAuction
 * @author Crypto Coders
 * @notice مزایده هلندی با پرداخت ETH بومی
 *
 * در مزایده هلندی، قیمت از مقدار اولیه بالاتر شروع می‌شود و با گذشت زمان
 * به‌صورت خطی کاهش پیدا می‌کند. اولین خریداری که قیمت فعلی را بپذیرد،
 * برنده مزایده خواهد بود.
 *
 * نکات طراحی:
 * - هر قرارداد فقط یک مزایده را مدیریت می‌کند.
 * - قیمت با گذشت زمان از startPrice به floorPrice کاهش می‌یابد.
 * - خریدار می‌تواند مبلغی بیشتر از قیمت فعلی ارسال کند؛ اضافه‌پرداخت
 *   به‌عنوان طلب خریدار ذخیره می‌شود و باید جداگانه برداشت شود.
 * - فروشنده نیز مبلغ فروش را با تابع مستقل برداشت می‌کند.
 * - انتقال ETH با الگوی Pull Payment و محافظ Reentrancy انجام می‌شود.
 * - این قرارداد فقط پرداخت ETH را مدیریت می‌کند و دارایی مورد مزایده
 *   (مثلاً NFT) را منتقل نمی‌کند.
 */

contract DutchAuction {
    // -----------------------------
    // متغیرهای اصلی مزایده
    // -----------------------------

    address payable public seller;

    uint256 public startTime;
    uint256 public endTime;

    // قیمت اولیه و قیمت کف مزایده، هر دو برحسب Wei
    uint256 public startPrice;
    uint256 public floorPrice;

    // مبلغی که خریدار باید در نهایت به فروشنده پرداخت کند
    uint256 public salePrice;

    address public buyer;

    bool public sold;
    bool public canceled;
    bool public proceedsClaimed;

    // طلب ETH کاربران؛ برای مثال اضافه‌پرداخت خریدار
    mapping(address => uint256) public pendingReturns;

    // محافظ ساده در برابر Reentrancy
    bool private locked;

    // -----------------------------
    // رویدادها
    // -----------------------------

    event AuctionCreated(
        address indexed seller,
        uint256 startPrice,
        uint256 floorPrice,
        uint256 startTime,
        uint256 endTime
    );

    event PriceUpdated(uint256 currentPrice);

    event ItemPurchased(
        address indexed buyer,
        uint256 price,
        uint256 overpayment
    );

    event RefundWithdrawn(address indexed account, uint256 amount);

    event ProceedsWithdrawn(address indexed seller, uint256 amount);

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
    // سازنده قرارداد
    // -----------------------------

    /**
     * @param _duration مدت مزایده برحسب ثانیه
     * @param _startPrice قیمت اولیه برحسب Wei
     * @param _floorPrice کمترین قیمت قابل قبول برحسب Wei
     */
    constructor(
        uint256 _duration,
        uint256 _startPrice,
        uint256 _floorPrice
    ) {
        require(_duration > 0, "Duration is zero");
        require(_floorPrice > 0, "Floor price is zero");
        require(_startPrice > _floorPrice, "Start must exceed floor");

        seller = payable(msg.sender);

        startTime = block.timestamp;
        endTime = block.timestamp + _duration;

        startPrice = _startPrice;
        floorPrice = _floorPrice;

        emit AuctionCreated(
            seller,
            startPrice,
            floorPrice,
            startTime,
            endTime
        );
    }

    // -----------------------------
    // محاسبه قیمت فعلی مزایده
    // -----------------------------

    /**
     * قیمت به‌صورت خطی از startPrice به floorPrice کاهش پیدا می‌کند.
     * پس از رسیدن به زمان پایان، قیمت برابر floorPrice خواهد بود.
     */
    function getCurrentPrice() public view returns (uint256) {
        if (block.timestamp <= startTime) {
            return startPrice;
        }

        if (block.timestamp >= endTime) {
            return floorPrice;
        }

        uint256 elapsed = block.timestamp - startTime;
        uint256 duration = endTime - startTime;
        uint256 priceDrop = startPrice - floorPrice;

        uint256 reduction = (priceDrop * elapsed) / duration;

        return startPrice - reduction;
    }

    // -----------------------------
    // خرید در مزایده
    // -----------------------------

    /**
     * اولین شخصی که قیمت فعلی را بپذیرد، خریدار مزایده می‌شود.
     *
     * اگر msg.value بیشتر از قیمت فعلی باشد، اضافه مبلغ به‌عنوان طلب
     * خریدار ذخیره می‌شود تا با withdrawRefund آن را برداشت کند.
     */
    function buy() external payable {
        require(!sold, "Already sold");
        require(!canceled, "Auction canceled");
        require(block.timestamp <= endTime, "Auction ended");
        require(msg.sender != seller, "Seller cannot buy");

        uint256 currentPrice = getCurrentPrice();

        require(msg.value >= currentPrice, "Insufficient ETH");

        sold = true;
        buyer = msg.sender;
        salePrice = currentPrice;

        uint256 overpayment = msg.value - currentPrice;

        if (overpayment > 0) {
            pendingReturns[msg.sender] += overpayment;
        }

        emit ItemPurchased(msg.sender, currentPrice, overpayment);
    }

    // -----------------------------
    // برداشت اضافه‌پرداخت خریدار
    // -----------------------------

    function withdrawRefund() external noReentrancy {
        uint256 amount = pendingReturns[msg.sender];

        require(amount > 0, "No refund");

        // ابتدا طلب صفر می‌شود تا از برداشت تکراری جلوگیری شود
        pendingReturns[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Refund failed");

        emit RefundWithdrawn(msg.sender, amount);
    }

    // -----------------------------
    // برداشت وجه توسط فروشنده
    // -----------------------------

    function withdrawProceeds()
        external
        onlySeller
        noReentrancy
    {
        require(sold, "Not sold");
        require(!proceedsClaimed, "Already claimed");

        proceedsClaimed = true;

        (bool success, ) = seller.call{value: salePrice}("");
        require(success, "Payment failed");

        emit ProceedsWithdrawn(seller, salePrice);
    }

    // -----------------------------
    // لغو مزایده توسط فروشنده
    // -----------------------------

    /**
     * فروشنده فقط پیش از فروش می‌تواند مزایده را لغو کند.
     * در این قرارداد وجهی برای شروع مزایده از فروشنده دریافت نمی‌شود.
     */
    function cancelAuction() external onlySeller {
        require(!sold, "Already sold");
        require(!canceled, "Already canceled");
        require(block.timestamp < endTime, "Auction time ended");

        canceled = true;

        emit AuctionCanceled();
    }

    // -----------------------------
    // اطلاعات کمکی
    // -----------------------------

    function getTimeLeft() external view returns (uint256) {
        if (block.timestamp >= endTime) {
            return 0;
        }

        return endTime - block.timestamp;
    }

    function getAuctionInfo()
        external
        view
        returns (
            address auctionSeller,
            uint256 currentPrice,
            uint256 auctionStartPrice,
            uint256 auctionFloorPrice,
            uint256 auctionEndTime,
            address auctionBuyer,
            uint256 finalSalePrice,
            bool auctionSold,
            bool auctionCanceled
        )
    {
        return (
            seller,
            getCurrentPrice(),
            startPrice,
            floorPrice,
            endTime,
            buyer,
            salePrice,
            sold,
            canceled
        );
    }
}
