//
//  MKChatC.m
//  JLIM4iPhone
//
//  Created by jimneylee on 14-5-20.
//  Copyright (c) 2014年 jimneylee. All rights reserved.
//

#import "IMChatC.h"
#import "IMManager.h"
#import "IMChatSendBar.h"
#import "IMEmotionMainView.h"
#import "IMChatShareMoreView.h"
#import "UIViewController+Camera.h"

#import "IMChatViewModel.h"
#import "IMMessageCellFactory.h"
#import "IMChatMessageEntityFactory.h"
#import "XMPPMessageArchiving_Message_CoreDataObject+ChatMessage.h"
#import "XMPPMessageArchiving_Contact_CoreDataObject+RecentContact.h"

#define DATE_LABEL_MARGIN 4.f
@interface MKChatDateLabel : UILabel

@end
@implementation MKChatDateLabel

- (void)drawTextInRect:(CGRect)rect {
    UIEdgeInsets insets = {DATE_LABEL_MARGIN, DATE_LABEL_MARGIN, DATE_LABEL_MARGIN, DATE_LABEL_MARGIN};
    return [super drawTextInRect:UIEdgeInsetsInsetRect(rect, insets)];
}

@end

static XMPPJID *currentChatBuddyJid = nil;

@interface IMChatC ()<UITableViewDelegate, UITableViewDataSource,
MKChatSendBarDelegate, MKEmotionDelegate, MKChatShareMoreViewDelegate>

@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) IMChatSendBar *chatSendBar;
@property (nonatomic, strong) IMEmotionMainView* emotionMainView;
@property (nonatomic, strong) IMChatShareMoreView* shareMoreView;

@property (nonatomic, assign) BOOL willShowEmtionOrShareMoreView;
@property (nonatomic, strong) IMChatViewModel *viewModel;
@property (nonatomic, strong) XMPPMessageArchiving_Contact_CoreDataObject *contact;

@end

@implementation IMChatC

+ (XMPPJID *)currentBuddyJid
{
    return currentChatBuddyJid;
}

+ (void)setCurrentBuddyJid:(XMPPJID *)jid
{
    currentChatBuddyJid = jid;
}

- (void)dealloc
{
    [[IMManager sharedManager].xmppStream removeDelegate:self delegateQueue:dispatch_get_main_queue()];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // 获取当前聊天联系人，清空未读消息数
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RESET_CURRENT_CONTACT_UNREAD_MESSAGES_COUNT"
                                                        object:self.viewModel.buddyJID userInfo:nil];
    
    [IMChatC setCurrentBuddyJid:nil];
}

- (instancetype)initWithBuddyJID:(XMPPJID *)buddyJID buddyName:(NSString *)buddyName
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        
        [IMChatC setCurrentBuddyJid:buddyJID];
        
        self.title = buddyName ?: buddyJID.user;
        self.hidesBottomBarWhenPushed = YES;
        
        self.viewModel = [[IMChatViewModel alloc] initWithModel:[[IMManager sharedManager] managedObjectContext_messageArchiving]];
        self.viewModel.buddyJID = buddyJID;
        
        [[IMManager sharedManager].xmppStream addDelegate:self delegateQueue:dispatch_get_main_queue()];
        
        @weakify(self);
        [self.viewModel.fetchLaterSignal subscribeNext:^(id x) {
            @strongify(self);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                if ([self isNearbyBottom]) {
                    [self scrollToBottomAnimated:YES];
                }
            });
        }];
        
        [self.viewModel.fetchEarlierSignal subscribeNext:^(NSIndexPath *indexPath) {
            @strongify(self);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
                if (indexPath) {
                    [self.tableView scrollToRowAtIndexPath:indexPath
                                          atScrollPosition:UITableViewScrollPositionTop animated:NO];
                }
                else {
                    [self scrollToBottomAnimated:YES];
                }
            });
        }];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    if ([self respondsToSelector:@selector(edgesForExtendedLayout)]) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }
    
    self.view.backgroundColor = [UIColor whiteColor];
    
    self.chatSendBar = [[IMChatSendBar alloc] initWithFunctionOptions:MKChatSendBarFunctionOption_Text
                        | MKChatSendBarFunctionOption_Emotion | MKChatSendBarFunctionOption_More];
    self.chatSendBar.delegate = self;
    self.chatSendBar.backgroundColor = RGBCOLOR(244, 244, 244);
    self.chatSendBar.bottom = self.view.height;
    
    CGFloat tableViewHeight = [UIScreen mainScreen].bounds.size.height - TTStatusBarHeight()
    - TTToolbarHeightForOrientation(self.interfaceOrientation) - self.chatSendBar.height;
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0.f, 0.f, self.view.width, tableViewHeight)
                                                  style:UITableViewStyleGrouped];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor whiteColor];
    self.tableView.backgroundView = [[UIView alloc] init];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.sectionHeaderHeight = 10.f;
    self.tableView.sectionFooterHeight = 0.f;
    
    [self.view addSubview:self.tableView];
    [self.view addSubview:self.chatSendBar];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(fetchEarlierMessageAction)
                  forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.refreshControl];

    UITapGestureRecognizer *tapGestrure = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                  action:@selector(tapHideKeyboardAction)];
    [self.tableView addGestureRecognizer:tapGestrure];
    
    self.willShowEmtionOrShareMoreView = NO;
    
    [self.viewModel fetchEarlierMessage];
    
    [self.tableView reloadData];
    [self scrollToBottomAnimated:YES];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self registerKeyboardNotifications];
    
    [self.tableView addSubview:self.refreshControl];
}

-(void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Private

- (void)registerKeyboardNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
}

- (void)tapHideKeyboardAction
{
    if ([self.chatSendBar makeTextViewResignFirstResponder]) {
        // 当前显示键盘，退出键盘
    }
    else {
        [self popdownSendBarAnimation];
    }
}

- (void)fetchEarlierMessageAction
{
    [self.viewModel fetchEarlierMessage];
    [self.refreshControl endRefreshing];
}

#pragma mark - UI Create

- (IMEmotionMainView *)emotionMainView
{
    // 显示表情选择框
    if (!_emotionMainView) {
        _emotionMainView = [[IMEmotionMainView alloc] initWithFrame:
                            CGRectMake(0.f, self.view.height, self.view.width, TT_KEYBOARD_HEIGHT)];
        _emotionMainView.EmotionDelegate = self;
        [self.view addSubview:_emotionMainView];
    }
    return _emotionMainView;
}

- (IMChatShareMoreView *)shareMoreView
{
    if (!_shareMoreView) {
        _shareMoreView = [[IMChatShareMoreView alloc] initWithFrame:
                          CGRectMake(0.f, self.view.height, self.view.width, TT_KEYBOARD_HEIGHT)];
        _shareMoreView.shareMoreDelegate = self;
        [self.view addSubview:_shareMoreView];
    }
    return _shareMoreView;
}

#pragma mark - Animation

- (void)popdownSendBarAnimation
{
    [UIView animateWithDuration:.3f animations:^{
        self.chatSendBar.bottom = self.view.height;
        self.tableView.height = self.chatSendBar.top;
        self.emotionMainView.top = self.chatSendBar.bottom;
        self.shareMoreView.top = self.chatSendBar.bottom;
    } completion:^(BOOL finished) {

    }];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
/**
 *  表情试图和分享更多试图的弹出切换策略：
 *  统一处理，只做前置显示
 */
- (void)popupEmotionViewOrShareMoreViewAnimation
{
    self.willShowEmtionOrShareMoreView = YES;
    self.emotionMainView.top = self.chatSendBar.bottom;
    self.shareMoreView.top = self.chatSendBar.bottom;
    
    [UIView animateWithDuration:.2f animations:^{
        
        self.emotionMainView.top = self.view.height - self.emotionMainView.height;
        self.shareMoreView.top = self.view.height - self.emotionMainView.height;
        self.chatSendBar.bottom = self.emotionMainView.top;
        self.tableView.height = self.chatSendBar.top;
    } completion:^(BOOL finished) {
        
        self.willShowEmtionOrShareMoreView = NO;
        [self scrollToBottomAnimated:YES];
    }];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)popdownEmotionViewOrShareMoreViewAnimation
{
    [UIView animateWithDuration:.2f animations:^{
        self.emotionMainView.top = self.view.height;
        self.shareMoreView.top = self.view.height;
    } completion:^(BOOL finished) {
    }];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)popupEmotionViewAnimation
{
    // create shareMoreView
    if (self.shareMoreView) {
        [self.view bringSubviewToFront:self.emotionMainView];
    }
    [self popupEmotionViewOrShareMoreViewAnimation];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)popdownEmotionViewAnimation
{
    [self popdownEmotionViewOrShareMoreViewAnimation];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)popupShareMoreViewAnimation
{
    // create emotionView
    if (self.emotionMainView) {
        [self.view bringSubviewToFront:self.shareMoreView];
    }
    [self.view bringSubviewToFront:self.shareMoreView];
    [self popupEmotionViewOrShareMoreViewAnimation];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)popdownShareMoreViewAnimation
{
    [self popdownEmotionViewOrShareMoreViewAnimation];
}

- (void)scrollToLastRow
{
    [self.tableView scrollToRowAtIndexPath:
     [NSIndexPath indexPathForRow:[self.viewModel numberOfItemsInSection:0] inSection:0]
                          atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

- (BOOL)isNearbyBottom
{
    CGFloat delta = 200.f;//200-80
    NSLog(@"offsety = %f, height = %f", self.tableView.contentOffset.y, self.tableView.contentSize.height - self.tableView.height);
    return self.tableView.contentOffset.y + delta > self.tableView.contentSize.height - self.tableView.height;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)scrollToBottomAnimated:(BOOL)animated
{
    [self.tableView scrollRectToVisible:CGRectMake(0.f, self.tableView.contentSize.height - self.tableView.height,
                                                   self.tableView.width, self.tableView.height) animated:animated];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)scrollToTopAnimated:(BOOL)animated
{
    [self.tableView scrollRectToVisible:CGRectMake(0.f, 0.f,
                                                   self.tableView.width, self.tableView.height) animated:animated];
}

#pragma mark - UIKeyboardNotification

- (void)keyboardWillShow:(NSNotification*)notification
{
    NSDictionary* info = [notification userInfo];
    UIViewAnimationCurve animationCurve = [[info valueForKey: UIKeyboardAnimationCurveUserInfoKey] intValue];
    NSTimeInterval animationDuration = [[info valueForKey: UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    CGRect keyboardBounds = [(NSValue *)[info objectForKey: UIKeyboardFrameEndUserInfoKey] CGRectValue];

    [UIView animateWithDuration:animationDuration animations:^{
        [UIView setAnimationCurve:animationCurve];
        
        self.chatSendBar.bottom = self.view.height - keyboardBounds.size.height;
        self.tableView.height = self.chatSendBar.top;
        self.emotionMainView.top = self.chatSendBar.bottom;
        self.shareMoreView.top = self.chatSendBar.bottom;

        // TODO: 底部一起上移效果更好些，但是需要深入考虑当只有几条时候，高度如何计算
        //self.tableView.bottom = self.chatSendBar.bottom - self.chatSendBar.height;
    } completion:^(BOOL finished) {
        
        [self scrollToBottomAnimated:YES];
    }];
}

- (void)keyboardWillHide:(NSNotification*)notification
{
    //[self popdownSendBarAnimation];
    
    // 键盘切换表情，消失键盘时，不需要执行下面的动画
    if (self.willShowEmtionOrShareMoreView) {
        return;
    }
    
    NSDictionary* info = [notification userInfo];
    UIViewAnimationCurve animationCurve = [[info valueForKey: UIKeyboardAnimationCurveUserInfoKey] intValue];
    NSTimeInterval animationDuration = [[info valueForKey: UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    [UIView animateWithDuration:animationDuration animations:^{
        [UIView setAnimationCurve:animationCurve];
        
        self.chatSendBar.bottom = self.view.height;
        self.tableView.height = self.chatSendBar.top;
        self.emotionMainView.top = self.chatSendBar.bottom;
        self.shareMoreView.top = self.chatSendBar.bottom;
        //self.tableView.bottom = self.chatSendBar.bottom - self.chatSendBar.height;
    } completion:^(BOOL finished) {
        
    }];
}

#pragma mark - MKChatSendBarDelegate

- (void)sendPlainMessage:(NSString *)plainMessage
{
    [self.viewModel sendMessageWithText:plainMessage];
}

- (void)showEmtionView
{
    [self popupEmotionViewAnimation];
}

- (void)showVoice
{

}

- (void)showKeyboard
{
    
}

- (void)showShareMoreView
{
    [self popupShareMoreViewAnimation];
}

- (void)didChangeHeight:(CGFloat)height
{
    [UIView animateWithDuration:.2f animations:^{
        self.tableView.height = self.chatSendBar.top;
    } completion:^(BOOL finished) {
//        [self scrollToBottomAnimated:NO];
    }];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - OSCEmotionDelegate
//////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)emotionSelectedWithName:(NSString*)name
{
    [self.chatSendBar insertEmotionName:name];
}

- (void)didEmotionViewDeleteAction
{
    [self.chatSendBar deleteLastCharTextView];
}

- (void)didEmotionViewSendAction
{
    [self.viewModel sendMessageWithText:self.chatSendBar.inputText];
}

#pragma mark - MKChatShareMoreViewDelegate

- (void)didPickPhotoFromLibrary
{
    @weakify(self);
    [self photoFromLibrary:^(id object) {
        
        @strongify(self);
        if (object) {
            [self.viewModel sendMessageWithImage:object];
        }
    } allowsEditing:NO];
}

- (void)didPickPhotoFromCamera
{
    @weakify(self);
    [self photoFromCamera:^(id object) {
        
        @strongify(self);
        if (object) {
            [self.viewModel sendMessageWithImage:object];
        }
    } allowsEditing:NO];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark UITableViewDataSource
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return [self.viewModel numberOfSections];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)sectionIndex
{
    return [self.viewModel numberOfItemsInSection:sectionIndex];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	static NSString *MessageTextCellIdentifier = @"MessageTextCell";
	static NSString *MessageImageCellIdentifier = @"MessageImageCell";
    static NSString *MessageVoiceCellIdentifier = @"MessageVoiceCell";
	
	XMPPMessageArchiving_Message_CoreDataObject *coreDataMessage = [self.viewModel objectAtIndexPath:indexPath];
    id message = coreDataMessage.chatMessage;
    MKMessageBaseCell *cell = nil;
    
    if ([message isKindOfClass:[IMChatMessageTextEntity class]]) {
        cell = [tableView dequeueReusableCellWithIdentifier:MessageTextCellIdentifier];
        if (!cell) {
            cell = [[MKMessageTextCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:MessageTextCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        [cell shouldUpdateCellWithObject:message];
    }
    
    else if ([message isKindOfClass:[IMChatMessageImageEntity class]]) {
        cell = [tableView dequeueReusableCellWithIdentifier:MessageImageCellIdentifier];
        if (!cell) {
            cell = [[MKMessageImageCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:MessageImageCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        [cell shouldUpdateCellWithObject:message];
    }
    else {
        cell = [tableView dequeueReusableCellWithIdentifier:MessageVoiceCellIdentifier];
        if (!cell) {
            cell = [[MKMessageBaseCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:MessageVoiceCellIdentifier];
        }
    }

    return cell;
}

#pragma mark - UITabelViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    XMPPMessageArchiving_Message_CoreDataObject *coreDataMessage = [self.viewModel objectAtIndexPath:indexPath];
    id message = coreDataMessage.chatMessage;
    
    if ([message isKindOfClass:[IMChatMessageTextEntity class]]) {
        return [MKMessageTextCell heightForObject:message atIndexPath:indexPath tableView:tableView];
    }
    
    else if ([message isKindOfClass:[IMChatMessageImageEntity class]]) {
        return [MKMessageImageCell heightForObject:message atIndexPath:indexPath tableView:tableView];
    }
    
    else return 44.f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return 20.f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *bgView = [[UIView alloc] initWithFrame:CGRectMake(0.f, 0.f, tableView.width, 20.f)];
    MKChatDateLabel *dateTextView = [[MKChatDateLabel alloc] initWithFrame:CGRectZero];
    dateTextView.textColor = [UIColor whiteColor];
    dateTextView.font = [UIFont systemFontOfSize:13.f];
    dateTextView.backgroundColor = [UIColor lightGrayColor];
    dateTextView.layer.cornerRadius = 4.f;
    dateTextView.layer.masksToBounds = YES;
    [bgView addSubview:dateTextView];
    
    NSString *title = [self.viewModel titleForHeaderInSection:section];
    dateTextView.text = title;
    [dateTextView sizeToFit];
    dateTextView.width = dateTextView.width + DATE_LABEL_MARGIN * 2;
    dateTextView.center = CGPointMake([UIScreen mainScreen].bounds.size.width / 2, bgView.height / 2);
    
    return bgView;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if ([self.chatSendBar makeTextViewResignFirstResponder]) {
        // 当前显示键盘，退出键盘
    }
    else {
        [self popdownSendBarAnimation];
    }
}

#pragma mark - XMPPStreamDelegate

- (void)xmppStream:(XMPPStream *)sender didSendMessage:(XMPPMessage *)message
{
    NSString *buddyBar = [[message attributeForName:@"to"] stringValue];
    XMPPJID *buddyJid = [XMPPJID jidWithString:buddyBar];
    
    if ([self.viewModel.buddyJID isEqualToJID:buddyJid options:XMPPJIDCompareBare]) {
        [self.chatSendBar clearInputTextView];
        [self.chatSendBar makeSendEnable];
    }
}

- (void)xmppStream:(XMPPStream *)sender didFailToSendMessage:(XMPPMessage *)message error:(NSError *)error
{
    NSString *buddyBar = [[message attributeForName:@"to"] stringValue];
    if ([self.viewModel.buddyJID.bare isEqualToString:buddyBar]) {
        [self.chatSendBar makeSendEnable];
    }
}

@end
