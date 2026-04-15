#import "IOSMCPQRCodeCell.h"
#import <Preferences/PSSpecifier.h>

@interface IOSMCPQRCodeCell ()

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *qrImageView;
@property (nonatomic, strong) UILabel *captionLabel;

@end

@implementation IOSMCPQRCodeCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) {
        return nil;
    }

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.backgroundColor = UIColor.whiteColor;
    _cardView.layer.cornerRadius = 14.0;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderWidth = 1.0;
    _cardView.layer.borderColor = [UIColor colorWithWhite:0.90 alpha:1.0].CGColor;
    [self.contentView addSubview:_cardView];

    _qrImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    _qrImageView.clipsToBounds = YES;
    [_cardView addSubview:_qrImageView];

    _captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _captionLabel.text = @"微信扫码关注公众号";
    _captionLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    _captionLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
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
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat insetX = 16.0;
    CGFloat insetY = 8.0;
    self.cardView.frame = CGRectInset(self.contentView.bounds, insetX, insetY);

    CGFloat captionHeight = 18.0;
    CGFloat innerInset = 12.0;
    self.captionLabel.frame = CGRectMake(innerInset,
                                         CGRectGetHeight(self.cardView.bounds) - captionHeight - 10.0,
                                         CGRectGetWidth(self.cardView.bounds) - innerInset * 2,
                                         captionHeight);
    self.qrImageView.frame = CGRectMake(innerInset,
                                        innerInset,
                                        CGRectGetWidth(self.cardView.bounds) - innerInset * 2,
                                        CGRectGetMinY(self.captionLabel.frame) - innerInset - 6.0);
}

@end
