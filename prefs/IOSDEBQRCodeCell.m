#import "IOSDEBQRCodeCell.h"
#import "IOSDEBLocalization.h"
#import <Preferences/PSSpecifier.h>

@interface IOSDEBQRCodeCell ()

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *qrImageView;
@property (nonatomic, strong) UILabel *captionLabel;

@end

@implementation IOSDEBQRCodeCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) {
        return nil;
    }

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    if (@available(iOS 13.0, *)) {
        _cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        _cardView.backgroundColor = [UIColor whiteColor];
    }
    _cardView.layer.cornerRadius = 14.0;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderWidth = 0.5;
    if (@available(iOS 13.0, *)) {
        _cardView.layer.borderColor = [UIColor separatorColor].CGColor;
    } else {
        _cardView.layer.borderColor = [UIColor colorWithWhite:0.85 alpha:1.0].CGColor;
    }
    [self.contentView addSubview:_cardView];

    _qrImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    _qrImageView.clipsToBounds = YES;
    _qrImageView.layer.cornerRadius = 8.0;
    [_cardView addSubview:_qrImageView];

    _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _captionLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    _captionLabel.numberOfLines = 0;
    if (@available(iOS 13.0, *)) {
        _captionLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        _captionLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1.0];
    }
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    [_cardView addSubview:_captionLabel];

    [self refreshCellContentsWithSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];

    NSString *imageName = [specifier propertyForKey:@"qrImageName"] ?: @"wechat_qr.jpg";
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    UIImage *image = [UIImage imageNamed:imageName inBundle:bundle compatibleWithTraitCollection:nil];
    self.qrImageView.image = image;

    NSString *caption = [specifier propertyForKey:@"caption"];
    if ([caption isKindOfClass:[NSString class]] && caption.length > 0) {
        self.captionLabel.text = caption;
    } else {
        self.captionLabel.text = @"职场阿江笔记";
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat insetX = 16.0;
    CGFloat insetY = 6.0;
    self.cardView.frame = CGRectInset(self.contentView.bounds, insetX, insetY);

    CGFloat innerInset = 16.0;
    CGFloat captionWidth = MAX(0.0, CGRectGetWidth(self.cardView.bounds) - innerInset * 2);
    CGFloat captionHeight = 24.0;
    self.captionLabel.frame = CGRectMake(innerInset,
                                         CGRectGetHeight(self.cardView.bounds) - captionHeight - 12.0,
                                         captionWidth,
                                         captionHeight);

    CGFloat availH = CGRectGetMinY(self.captionLabel.frame) - innerInset - 8.0;
    CGFloat availW = CGRectGetWidth(self.cardView.bounds) - innerInset * 2;
    CGFloat qrSize = MIN(availW, availH);
    CGFloat qrX = (CGRectGetWidth(self.cardView.bounds) - qrSize) / 2.0;
    CGFloat qrY = innerInset + (availH - qrSize) / 2.0;
    self.qrImageView.frame = CGRectMake(qrX, qrY, qrSize, qrSize);
}

@end
