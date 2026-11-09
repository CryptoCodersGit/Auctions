
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    =========================================================
                    Crypto Coders
             Real-World Smart Contract Projects
    =========================================================

    نام پروژه: Decentralized Auction System

    هدف این آموزش:
    ساخت یک سیستم مزایده غیرمتمرکز با زبان Solidity
    که کاربران بتوانند با ETH در آن پیشنهاد قیمت ثبت کنند.

    امکانات قرارداد:

    1. ایجاد مزایده توسط فروشنده
    2. تعیین قیمت پایه و مدت زمان مزایده
    3. ثبت پیشنهاد قیمت توسط کاربران
    4. نگهداری بالاترین پیشنهاد و پیشنهاددهنده
    5. ذخیره مبلغ پیشنهادهای قبلی برای بازپرداخت
    6. برداشت وجه توسط پیشنهاددهندگان قبلی
    7. پایان مزایده پس از اتمام زمان
    8. دریافت مبلغ نهایی توسط فروشنده
    9. امکان لغو مزایده قبل از ثبت اولین پیشنهاد
    10. جلوگیری از حملات Reentrancy

    نکته:
    این نسخه فقط پرداخت ETH و منطق مزایده را مدیریت می‌کند.
    انتقال مالکیت NFT یا کالای فیزیکی در آن پیاده‌سازی نشده است.

    این قرارداد آموزشی است و قبل از استفاده با دارایی واقعی
    باید بررسی امنیتی و Audit تخصصی انجام شود.
*/

contract DecentralizedAuction {

    // -----------------------------------------------------
    // 1. متغیرهای اصلی قرارداد
    // -----------------------------------------------------

    // آدرس فروشنده؛ کسی که مزایده را ایجاد کرده است
    address payable public seller;

    // زمان شروع مزایده
    uint256 public startTime;

    // زمان پایان مزایده
    uint256 public endTime;

    // حداقل قیمت قابل قبول برای اولین پیشنهاد
    uint256 public reservePrice;

    // بالاترین پیشنهاد ثبت شده
    uint256 public highestBid;

    // آدرس کسی که بالاترین پیشنهاد را ثبت کرده است
    address public highestBidder;

    // مبلغی که هر کاربر می‌تواند از قرارداد پس بگیرد
    mapping(address => uint256) public pendingReturns;

    // آیا مزایده پایان یافته است؟
    bool public ended;

    // آیا مزایده لغو شده است؟
    bool public canceled;

    // آیا فروشنده مبلغ مزایده را دریافت کرده است؟
    bool public proceedsClaimed;

    // متغیر محافظ برای جلوگیری از Reentrancy
    bool private locked;


    // -----------------------------------------------------
    // 2. رویدادهای قرارداد
    // -----------------------------------------------------

    // زمانی که یک پیشنهاد جدید ثبت می‌شود
    event BidPlaced(
        address indexed bidder,
        uint256 amount
    );

    // زمانی که کاربر مبلغ قبلی خود را پس می‌گیرد
    event RefundWithdrawn(
        address indexed bidder,
        uint256 amount
    );

    // زمانی که مزایده پایان داده می‌شود
    event AuctionEnded(
        address indexed winner,
        uint256 amount
    );

    // زمانی که فروشنده مبلغ مزایده را دریافت می‌کند
    event SellerPaid(
        address indexed seller,
        uint256 amount
    );

    // زمانی که مزایده لغو می‌شود
    event AuctionCanceled();


    // -----------------------------------------------------
    // 3. Modifierها
    // -----------------------------------------------------

    // فقط فروشنده اجازه اجرای تابع را دارد
    modifier onlySeller() {
        require(
            msg.sender == seller,
            "Only seller can call this function"
        );
        _;
    }

    // جلوگیری از اجرای مجدد تابع در زمان انتقال ETH
    modifier noReentry() {
        require(!locked, "Reentrancy detected");

        locked = true;

        _;

        locked = false;
    }


    // -----------------------------------------------------
    // 4. سازنده قرارداد (Constructor)
    // -----------------------------------------------------

    /*
        هنگام Deploy:

        _duration:
        مدت زمان مزایده بر حسب ثانیه

        _reservePrice:
        حداقل قیمت اولین پیشنهاد بر حسب Wei

        آدرس Deploy کننده به عنوان فروشنده ذخیره می‌شود.
    */

    constructor(
        uint256 _duration,
        uint256 _reservePrice
    ) {

        // مدت زمان مزایده باید بیشتر از صفر باشد
        require(
            _duration > 0,
            "Duration must be greater than zero"
        );

        // قیمت پایه باید بیشتر از صفر باشد
        require(
            _reservePrice > 0,
            "Reserve price must be greater than zero"
        );

        // ذخیره آدرس فروشنده
        seller = payable(msg.sender);

        // ثبت زمان شروع مزایده
        startTime = block.timestamp;

        // محاسبه زمان پایان مزایده
        endTime = block.timestamp + _duration;

        // ذخیره قیمت پایه
        reservePrice = _reservePrice;
    }


    // -----------------------------------------------------
    // 5. ثبت پیشنهاد قیمت (Place Bid)
    // -----------------------------------------------------

    /*
        کاربران با ارسال ETH می‌توانند پیشنهاد قیمت بدهند.

        قوانین:

        1. مزایده نباید پایان یافته یا لغو شده باشد.
        2. زمان مزایده باید هنوز تمام نشده باشد.
        3. فروشنده نمی‌تواند در مزایده خودش شرکت کند.
        4. اولین پیشنهاد باید حداقل برابر قیمت پایه باشد.
        5. پیشنهادهای بعدی باید از بالاترین پیشنهاد بیشتر باشند.

        اگر پیشنهاد جدید ثبت شود:
        مبلغ پیشنهاد قبلی به عنوان طلب کاربر قبلی ذخیره می‌شود.
    */

    function placeBid() external payable {

        // بررسی وضعیت مزایده
        require(
            !ended && !canceled,
            "Auction is not active"
        );

        // بررسی زمان پایان مزایده
        require(
            block.timestamp < endTime,
            "Auction time has ended"
        );

        // فروشنده نمی‌تواند پیشنهاد ثبت کند
        require(
            msg.sender != seller,
            "Seller cannot bid"
        );

        // مبلغ پیشنهادی باید بیشتر از صفر باشد
        require(
            msg.value > 0,
            "Bid must be greater than zero"
        );

        // اگر هنوز پیشنهادی ثبت نشده است
        if (highestBidder == address(0)) {

            // اولین پیشنهاد باید حداقل قیمت پایه باشد
            require(
                msg.value >= reservePrice,
                "Bid is below reserve price"
            );

        } else {

            // پیشنهاد جدید باید از پیشنهاد قبلی بیشتر باشد
            require(
                msg.value > highestBid,
                "Bid must be higher than current bid"
            );

            // مبلغ پیشنهاد قبلی را برای کاربر قبلی ذخیره می‌کنیم
            pendingReturns[highestBidder] += highestBid;
        }

        // ثبت پیشنهاد جدید به عنوان بالاترین پیشنهاد
        highestBid = msg.value;

        // ثبت آدرس پیشنهاددهنده جدید
        highestBidder = msg.sender;

        // انتشار رویداد ثبت پیشنهاد
        emit BidPlaced(msg.sender, msg.value);
    }


    // -----------------------------------------------------
    // 6. پس گرفتن مبلغ پیشنهاد قبلی (Withdraw Refund)
    // -----------------------------------------------------

    /*
        وقتی کاربری توسط یک پیشنهاد بالاتر کنار زده می‌شود،
        مبلغ ETH او در pendingReturns ذخیره می‌شود.

        کاربر می‌تواند با اجرای این تابع مبلغ خود را پس بگیرد.

        از الگوی Checks-Effects-Interactions استفاده می‌کنیم:

        1. بررسی موجودی قابل برداشت
        2. صفر کردن طلب کاربر
        3. انتقال ETH
    */

    function withdrawRefund()
        external
        noReentry
    {
        // مبلغ قابل برداشت کاربر
        uint256 amount = pendingReturns[msg.sender];

        // باید مبلغی برای برداشت وجود داشته باشد
        require(
            amount > 0,
            "No refund available"
        );

        // ابتدا طلب کاربر را صفر می‌کنیم
        pendingReturns[msg.sender] = 0;

        // سپس ETH را به کاربر انتقال می‌دهیم
        (bool success, ) = payable(msg.sender).call{
            value: amount
        }("");

        // اگر انتقال ناموفق بود، کل تراکنش برمی‌گردد
        require(
            success,
            "Refund transfer failed"
        );

        // انتشار رویداد برداشت وجه
        emit RefundWithdrawn(msg.sender, amount);
    }


    // -----------------------------------------------------
    // 7. پایان دادن به مزایده (End Auction)
    // -----------------------------------------------------

    /*
        پس از اتمام زمان مزایده، هر کاربری می‌تواند
        این تابع را اجرا کند.

        در این تابع فقط وضعیت مزایده تغییر می‌کند.
        انتقال ETH در تابع جداگانه انجام خواهد شد.
    */

    function endAuction() external {

        // مزایده نباید قبلاً پایان یافته باشد
        require(
            !ended,
            "Auction already ended"
        );

        // مزایده نباید لغو شده باشد
        require(
            !canceled,
            "Auction was canceled"
        );

        // زمان مزایده باید تمام شده باشد
        require(
            block.timestamp >= endTime,
            "Auction is still active"
        );

        // ثبت پایان مزایده
        ended = true;

        // اعلام نتیجه مزایده
        emit AuctionEnded(
            highestBidder,
            highestBid
        );
    }


    // -----------------------------------------------------
    // 8. دریافت مبلغ توسط فروشنده (Withdraw Proceeds)
    // -----------------------------------------------------

    /*
        فقط فروشنده می‌تواند مبلغ نهایی مزایده را دریافت کند.

        شرایط:

        1. مزایده باید پایان یافته باشد.
        2. مزایده نباید لغو شده باشد.
        3. حداقل یک پیشنهاد ثبت شده باشد.
        4. فروشنده قبلاً مبلغ را دریافت نکرده باشد.
    */

    function withdrawProceeds()
        external
        onlySeller
        noReentry
    {
        // بررسی پایان مزایده
        require(
            ended,
            "Auction has not ended"
        );

        // مزایده نباید لغو شده باشد
        require(
            !canceled,
            "Auction was canceled"
        );

        // باید برنده‌ای وجود داشته باشد
        require(
            highestBidder != address(0),
            "No bids were placed"
        );

        // جلوگیری از برداشت دوباره
        require(
            !proceedsClaimed,
            "Proceeds already claimed"
        );

        // مبلغ قابل پرداخت به فروشنده
        uint256 amount = highestBid;

        // ابتدا وضعیت برداشت را تغییر می‌دهیم
        proceedsClaimed = true;

        // سپس ETH را به فروشنده انتقال می‌دهیم
        (bool success, ) = seller.call{
            value: amount
        }("");

        // بررسی موفقیت انتقال
        require(
            success,
            "Payment to seller failed"
        );

        // انتشار رویداد پرداخت به فروشنده
        emit SellerPaid(seller, amount);
    }


    // -----------------------------------------------------
    // 9. لغو مزایده (Cancel Auction)
    // -----------------------------------------------------

    /*
        فقط فروشنده می‌تواند مزایده را لغو کند.

        اما فقط زمانی که هنوز هیچ پیشنهادی ثبت نشده باشد.

        پس از ثبت اولین پیشنهاد، امکان لغو وجود ندارد؛
        چون این کار می‌تواند حقوق پیشنهاددهندگان را
        تحت تأثیر قرار دهد.
    */

    function cancelAuction()
        external
        onlySeller
    {
        // مزایده نباید پایان یافته باشد
        require(
            !ended,
            "Auction already ended"
        );

        // مزایده نباید قبلاً لغو شده باشد
        require(
            !canceled,
            "Auction already canceled"
        );

        // هنوز نباید هیچ پیشنهادی ثبت شده باشد
        require(
            highestBidder == address(0),
            "Cannot cancel after first bid"
        );

        // ثبت وضعیت لغو
        canceled = true;

        // انتشار رویداد لغو
        emit AuctionCanceled();
    }


    // -----------------------------------------------------
    // 10. مشاهده زمان باقی‌مانده (Get Time Left)
    // -----------------------------------------------------

    /*
        این تابع زمان باقی‌مانده مزایده را بر حسب ثانیه
        برمی‌گرداند.

        اگر مزایده پایان یافته، لغو شده یا زمان آن تمام شده
        باشد، مقدار صفر برگردانده می‌شود.
    */

    function getTimeLeft()
        external
        view
        returns (uint256)
    {
        // اگر مزایده پایان یافته یا لغو شده باشد
        if (ended || canceled) {
            return 0;
        }

        // اگر زمان مزایده تمام شده باشد
        if (block.timestamp >= endTime) {
            return 0;
        }

        // محاسبه زمان باقی‌مانده
        return endTime - block.timestamp;
    }


    // -----------------------------------------------------
    // 11. مشاهده اطلاعات مزایده (Get Auction Info)
    // -----------------------------------------------------

    /*
        این تابع اطلاعات اصلی مزایده را یکجا برمی‌گرداند
        تا بررسی وضعیت قرارداد ساده‌تر شود.
    */

    function getAuctionInfo()
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256,
            address,
            bool,
            bool
        )
    {
        return (
            seller,
            reservePrice,
            highestBid,
            endTime,
            highestBidder,
            ended,
            canceled
        );
    }
}
