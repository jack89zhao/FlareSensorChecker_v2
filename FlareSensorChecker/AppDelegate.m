//
//  AppDelegate.m
//  FlareSensorChecker
//
//  Created by Jackie Wang on 2020/4/28.
//  Copyright © 2020 Jackie Wang. All rights reserved.
//

#import "AppDelegate.h"
#import "PortCheckerWindowController.h"
#import "IOCheckerWindowController.h"
#import "LTSMC.h"

#define K_DEFAULT_ENCODER_RATIO     (100)

@interface AppDelegate () <NSTableViewDelegate, NSTableViewDataSource>
{
    int _controllerID;
    BOOL _connected;
    BOOL _isMoving;
    BOOL _isStopCalibrated;
    int _selectedAxis;
    int _shieldAxis;
    NSMutableArray *_tableDataSource;
    NSArray *_tableColumnIdentifier;
    NSDictionary *_axisParams;
    PortCheckerWindowController *_portWindowController;
}
@property (weak) IBOutlet NSTableView *tableView;
@property (unsafe_unretained) IBOutlet NSTextView *failMsgText;
@property (weak) IBOutlet NSWindow *window;
@property (weak) IBOutlet NSComboBox *cbAxis;
@end

@implementation AppDelegate

- (void)loadTableDataSource {
    NSMutableArray *keys = [NSMutableArray new];
    
    for (NSTableColumn *tableColumn in [self.tableView tableColumns]) {
        [keys addObject:tableColumn.identifier];
    }
    _tableColumnIdentifier = [keys copy];
    
    for (int row = 0; row < 12; row++) {
        NSMutableDictionary *rowDict = [NSMutableDictionary new];
        for (int col = 0; col < 8; col++) {
            if (col == 0) {
                [rowDict setObject:@(row+1) forKey:keys[col]];
            } else if (col == 6) {
                [rowDict setObject:@"--" forKey:keys[col]];
            } else if (col == 7) {
                [rowDict setObject:@"--Pending--" forKey:keys[col]];
            } else {
                [rowDict setObject:@(0) forKey:keys[col]];
            }
        }
        [_tableDataSource addObject:rowDict];
    }
    
    [self.tableView reloadData];
}

- (NSString *)currentTimeString {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"[yyyy-MM-dd HH:mm:ss]:"];
    return [formatter stringFromDate:NSDate.date];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    if (!_tableDataSource) {
        _tableDataSource = [NSMutableArray new];
    }
    
    if (!_portWindowController) {
        _portWindowController = [[PortCheckerWindowController alloc] init];
    }
    
    if (!_axisParams) {
        NSString *path = [NSBundle.mainBundle pathForResource:@"Profile" ofType:@"plist"];
        _axisParams = [NSDictionary dictionaryWithContentsOfFile:path];
    }
//    _selectedAxis = 1;
    
    [self.tableView setRowSizeStyle:NSTableViewRowSizeStyleCustom];
    [self loadTableDataSource];
    
    NSString *str = [NSString stringWithFormat:@"%@ Success to launch application\n", [self currentTimeString]];
    NSAttributedString *attributeString = [[NSAttributedString alloc] initWithString:str attributes:@{NSForegroundColorAttributeName : NSColor.darkGrayColor}];
    
    self.failMsgText.editable = NO;
    [self.failMsgText.textStorage appendAttributedString:attributeString];
    [self.failMsgText scrollPageDown:self];
    
    _shieldAxis = 9;
    [self appendMessage:@"Shield 9 axis when run calibration" color:NSColor.darkGrayColor];
    
    [NSThread detachNewThreadSelector:@selector(checkSensor) toTarget:self withObject:nil];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
    if (_connected) {
        smc_stop(_controllerID, _selectedAxis, 0);
        
        nmcs_clear_card_errcode(_controllerID);   // clear card error
        nmcs_clear_errcode(_controllerID,0);      // clear bus error
        
        for (int axis = 1; axis <= 12; axis++) {
            nmcs_clear_axis_errcode(_controllerID, axis);
        }
        
        int rtn = 0;
        for (int i = 1; i < 13 ; i++) {
            rtn |= smc_write_sevon_pin(_controllerID, i, 1);
            usleep(5000);
        }
        
        smc_board_close(_controllerID);
        _connected = NO;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    [self.failMsgText.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];
    NSString *filename = [NSString stringWithFormat:@"%@/Documents/Flare/Logs/checker.log", NSHomeDirectory()];
    [self.failMsgText.textStorage.string writeToFile:filename atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

// disable / enable toolbar item.
- (void)switchStateToolbarItem:(NSToolbarItem *)sender enable:(BOOL)enabled {
    [sender setAction:enabled ? @selector(connectToolbar:) : nil];
}

- (BOOL)setAllAxisParams {
    BOOL flag = false;
    
    for (int axis = 1; axis <= 12; axis++) {
        int rtn = 0;
        double ratio = 1;
        BOOL canMove = true;
        NSDictionary *selectAxisParam = _axisParams[[NSString stringWithFormat:@"axis%d", axis]];
        
        if (selectAxisParam) {
            ratio = [selectAxisParam[@"pp_ratio"] doubleValue];
            rtn = smc_set_profile_unit(_controllerID,
                                       _selectedAxis,
                                       [selectAxisParam[@"start_speed"] doubleValue] * ratio,
                                       [selectAxisParam[@"run_speed"] doubleValue] * ratio,
                                       [selectAxisParam[@"acc_time"] doubleValue],
                                       [selectAxisParam[@"acc_time"] doubleValue],
                                       [selectAxisParam[@"stop_speed"] doubleValue] * ratio);
            
            if (rtn) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_s_profile(_controllerID, _selectedAxis, 0, [selectAxisParam[@"smooth_time"] doubleValue]))) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_home_pin_logic(_controllerID, _selectedAxis, [selectAxisParam[@"home_level"] intValue], 0))) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_homemode(_controllerID,
                                             _selectedAxis,
                                             [selectAxisParam[@"home_dir"] intValue],
                                             1,
                                             [selectAxisParam[@"home_mode"] intValue],
                                             0)))
            {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_home_profile_unit(_controllerID,
                                                      _selectedAxis,
                                                      [selectAxisParam[@"start_speed"] doubleValue] * ratio,
                                                      [selectAxisParam[@"home_speed"] doubleValue] * ratio,
                                                      [selectAxisParam[@"acc_time"] doubleValue],
                                                      0)))
            {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            flag &= canMove;
        }
    }
    
    return flag;
}

- (IBAction)showHelp:(NSMenuItem *)sender {
    NSString *path = [NSBundle.mainBundle pathForResource:@"FlareSensorChecker (v2.0.0) user manunals" ofType:@"pdf"];
    [[NSWorkspace sharedWorkspace] openFile:path];
}

- (IBAction)showLogo:(NSButton *)sender {
    NSImageView *imageView = [NSImageView imageViewWithImage:[NSImage imageNamed:@"MT_Name.png"]];
    [imageView setImageScaling:NSImageScaleProportionallyDown];
    [imageView setFrame:NSMakeRect(0, 0, 600, 60)];
    NSViewController *viewController = [[NSViewController alloc] init];
    viewController.view = [[NSView alloc] initWithFrame:imageView.frame];
    [viewController.view addSubview:imageView];
    
    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = viewController;
    
    if (@available(macOS 10.14, *)) {
        popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantLight];
    } else {
        // Fallback on earlier versions
        popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    }
    popover.behavior = NSPopoverBehaviorTransient;
    [popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}

- (IBAction)shieldAxisToCalibration:(NSMenuItem *)sender {
    if (sender.state == NSControlStateValueOn) {
        sender.state = NSControlStateValueOff;
        _shieldAxis = -1;
        [self appendMessage:@"Unshield 9 axis when run calibration" color:NSColor.blueColor];
    } else {
        sender.state = NSControlStateValueOn;
        _shieldAxis = 9;
        [self appendMessage:@"Shield 9 axis when run calibration" color:NSColor.blueColor];
    }
}

- (IBAction)ioChecker:(NSToolbarItem *)sender {
    static IOCheckerWindowController *ioCheckerController = nil;
    
    if (!ioCheckerController) {
        ioCheckerController = [[IOCheckerWindowController alloc] initWithControllerState:_connected];
    }
    
    [self.window beginSheet:ioCheckerController.window completionHandler:^(NSModalResponse returnCode) {
        
    }];
}

- (IBAction)portChecker:(NSToolbarItem *)sender {
    [_portWindowController checkPortname];
    
    [self.window beginSheet:_portWindowController.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSModalResponseOK) {
            
        }
    }];
}

- (IBAction)connectToolbar:(NSToolbarItem *)sender {
    if ([sender.label isEqualToString:@"Connect"]) {
        [self switchStateToolbarItem:sender enable:NO];
        [self appendMessage:[NSString stringWithFormat:@"Try to connect controller"] color:NSColor.blueColor];
        
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            if (0 == (self->_controllerID = smc_board_init(0, 2, "192.168.5.11", 0))) {
                WORD cardNum;
                DWORD cardTypeList;
                WORD cardIdList;
                smc_get_CardInfList(&cardNum, &cardTypeList, &cardIdList);
                nmcs_clear_card_errcode(self->_controllerID);   // clear card error
                nmcs_clear_errcode(self->_controllerID,0);      // clear bus error
                nmcs_set_alarm_clear(self->_controllerID,2,0);
                
                for (int axis = 1; axis <= 12; axis++) {
                    nmcs_clear_axis_errcode(self->_controllerID, axis);
                }
                
                int rtn = 0;
                WORD inmode = 3;
                
                for (int axis = 1; axis < 13 ; axis++) {
                    if (0 != (rtn = smc_write_sevon_pin(self->_controllerID, axis, 0))) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self showExecuteErrorMessage:rtn];
                        });
                    }
                    usleep(50000);
                    
                    if (0 != (rtn = smc_set_counter_inmode(self->_controllerID, axis, inmode))) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self showExecuteErrorMessage:rtn];
                        });
                    }
                    
                    if (0 != (rtn = smc_set_encoder_unit(self->_controllerID, axis, K_DEFAULT_ENCODER_RATIO))) {         // 设置指定轴编码器脉冲计数值
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self showExecuteErrorMessage:rtn];
                        });
                    }
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_cbAxis selectItemAtIndex:0];
                    [self selectAxis:self->_cbAxis];
                    
                    [self switchStateToolbarItem:sender enable:YES];
                    sender.label = @"Disconnect";
                    [sender setImage:[NSImage imageNamed:@"disconnect.png"]];
                    
                    [self appendMessage:@"Success to connect controller." color:NSColor.darkGrayColor];
                });
                
                [self setAllAxisParams];
                smc_write_outbit(self->_controllerID, 26, 0);
                sleep(1);
                self->_connected = YES;
                [self->_portWindowController setConnectState:self->_connected];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showExecuteErrorMessage:self->_controllerID];
                    NSAlert *alert = [NSAlert new];
                    alert.informativeText = @"Connect fail";
                    alert.messageText = @"Error";
                    [alert runModal];
                    [self switchStateToolbarItem:sender enable:YES];
                });
            }
        });
    } else {
        [self switchStateToolbarItem:sender enable:NO];
        [self appendMessage:[NSString stringWithFormat:@"Try to disconnect controller"] color:NSColor.blueColor];
        
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            nmcs_clear_card_errcode(self->_controllerID);   // clear card error
            nmcs_clear_errcode(self->_controllerID,0);      // clear bus error
            
            for (int axis = 1; axis <= 12; axis++) {
                nmcs_clear_axis_errcode(self->_controllerID, axis);
            }
            usleep(20000);
            
            int rtn = 0;
            for (int i = 1; i < 13 ; i++) {
                if (0 != (rtn = smc_write_sevon_pin(self->_controllerID, i, 1))) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self showExecuteErrorMessage:rtn];
                    });
                }
                usleep(50000);
            }
            
            rtn = smc_board_close(self->_controllerID);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (rtn) {
                    sender.label = @"Disconnect";
                    [self showExecuteErrorMessage:rtn];
                } else {
                    sender.label = @"Connect";
                    [sender setImage:[NSImage imageNamed:@"connect.png"]];
                    [self appendMessage:@"Success to disconnect controller." color:NSColor.darkGrayColor];
                }
                [self switchStateToolbarItem:sender enable:YES];
            });
            smc_write_outbit(self->_controllerID, 26, 1);
            self->_connected = NO;
            [self->_portWindowController setConnectState:self->_connected];
        });
    }
}

- (IBAction)selectAxis:(NSComboBox *)sender {
    NSString *axisString = sender.objectValueOfSelectedItem;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d+"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    
    if (regex) {
        NSTextCheckingResult *tcr = [regex firstMatchInString:axisString options:NSMatchingReportCompletion range:NSMakeRange(0, axisString.length)];
        if (tcr) {
            int axis = [[axisString substringWithRange:tcr.range] intValue];
            _selectedAxis = axis;
            [self appendMessage:[NSString stringWithFormat:@"Select axis %d", _selectedAxis] color:NSColor.blueColor];
        }
    }
}

- (IBAction)showAxisHelp:(NSButton *)sender {
    NSImageView *imageView = [NSImageView imageViewWithImage:[NSImage imageNamed:@"axisid.jpg"]];
    [imageView setFrame:NSMakeRect(0, 0, 415, 280)];
    NSViewController *viewController = [[NSViewController alloc] init];
    viewController.view = [[NSView alloc] initWithFrame:imageView.frame];
    [viewController.view addSubview:imageView];
    
    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = viewController;
    
    if (@available(macOS 10.14, *)) {
        popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    } else {
        // Fallback on earlier versions
        popover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    }
    popover.behavior = NSPopoverBehaviorTransient;
    [popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxX];
}

- (IBAction)move:(NSButton *)sender {
    int rtn = 0;
    int direction = 1;
    double ratio = 1;
    BOOL canMove = YES;
    
    if ([sender.title isEqualToString:@"Move+"]) {
        direction = 1;
    } else {
        direction = 0;
    }
    
    if (_connected) {
        for (int axis = 1; axis <= 12; axis++) {
            smc_stop(_controllerID, axis, 0);
        }
        
        NSString *msg = [NSString stringWithFormat:@"Move axis %d to %@ limit", _selectedAxis, direction ? @"positive" : @"negative"];
        [self appendMessage:msg color:NSColor.blueColor];
        
        NSDictionary *selectAxisParam = _axisParams[[NSString stringWithFormat:@"axis%d", _selectedAxis]];
        
        if (selectAxisParam) {
            ratio = [selectAxisParam[@"pp_ratio"] doubleValue];
            rtn = smc_set_profile_unit(_controllerID,
                                       _selectedAxis,
                                       [selectAxisParam[@"start_speed"] doubleValue] * ratio,
                                       [selectAxisParam[@"run_speed"] doubleValue] * ratio,
                                       [selectAxisParam[@"acc_time"] doubleValue],
                                       [selectAxisParam[@"acc_time"] doubleValue],
                                       [selectAxisParam[@"stop_speed"] doubleValue] * ratio);
            
            if (rtn) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_s_profile(_controllerID, _selectedAxis, 0, [selectAxisParam[@"smooth_time"] doubleValue]))) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (canMove) {
                if (0 != (rtn = smc_vmove(_controllerID, _selectedAxis, direction))) {
                    [self showExecuteErrorMessage:rtn];
                }
            } else {
                [self appendMessage:[NSString stringWithFormat:@"Can't move axis %d because of some error happened", _selectedAxis] color:NSColor.redColor];
            }
        } else {        // default value.
            switch (_selectedAxis) {
                case 1: ratio = 100; break;
                case 2:
                case 3: ratio = 2500; break;
                case 4: ratio = 15000; break;
                case 5:
                case 6:
                case 7:
                case 8: ratio = 1000; break;
                case 9: ratio = 40000; break;
                case 10: ratio = 800; break;
                case 11:
                case 12: ratio = 2000; break;
                default: break;
            }
            
            rtn |= smc_set_profile_unit(_controllerID, _selectedAxis, 5.0 * ratio, 15.0 * ratio, 2, 2, 5 * ratio);
            rtn |= smc_set_s_profile(_controllerID, _selectedAxis, 0, 0.1);
            rtn |= smc_vmove(_controllerID, _selectedAxis, direction);
            
            if (rtn != 0) {
                [self showExecuteErrorMessage:rtn];
            }
        }
        
        _isMoving = YES;
        sender.enabled = NO;
        __weak NSButton *button = sender;
        
        if (canMove) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                while(smc_check_done(self->_controllerID, self->_selectedAxis)==0) { usleep(10000); } //等待运动停止
                dispatch_async(dispatch_get_main_queue(), ^{
                    button.enabled = YES;
                    self->_isMoving = NO;
                    [self appendMessage:[NSString stringWithFormat:@"Success to move axis %d using vmove", self->_selectedAxis] color:NSColor.darkGrayColor];
                });
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                button.enabled = YES;
                self->_isMoving = NO;
            });
        }
    }
}

- (IBAction)moveToOrigin:(NSButton *)sender {
    if (_connected) {
        for (int axis = 1; axis <= 12; axis++) {
            smc_stop(_controllerID, axis, 0);
        }
        
        [self appendMessage:[NSString stringWithFormat:@"Move axis %d to origin", _selectedAxis] color:NSColor.blueColor];
        
        __block int rtn = 0;
        double ratio = 1;
        BOOL canMove = true;
        NSDictionary *selectAxisParam = _axisParams[[NSString stringWithFormat:@"axis%d", _selectedAxis]];
        
        if (selectAxisParam) {
            ratio = [selectAxisParam[@"pp_ratio"] doubleValue];
            rtn = smc_set_profile_unit(_controllerID,
                                       _selectedAxis,
                                       [selectAxisParam[@"start_speed"] doubleValue] * ratio,
                                       [selectAxisParam[@"run_speed"] doubleValue] * ratio,
                                       [selectAxisParam[@"acc_time"] doubleValue],
                                       [selectAxisParam[@"acc_time"] doubleValue],
                                       [selectAxisParam[@"stop_speed"] doubleValue] * ratio);
            
            if (rtn) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_s_profile(_controllerID, _selectedAxis, 0, [selectAxisParam[@"smooth_time"] doubleValue]))) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_home_pin_logic(_controllerID, _selectedAxis, [selectAxisParam[@"home_level"] intValue], 0))) {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_homemode(_controllerID,
                                             _selectedAxis,
                                             [selectAxisParam[@"home_dir"] intValue],
                                             1,
                                             [selectAxisParam[@"home_mode"] intValue],
                                             0)))
            {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (0 != (rtn = smc_set_home_profile_unit(_controllerID,
                                                      _selectedAxis,
                                                      [selectAxisParam[@"start_speed"] doubleValue] * ratio,
                                                      [selectAxisParam[@"home_speed"] doubleValue] * ratio,
                                                      [selectAxisParam[@"acc_time"] doubleValue],
                                                      0)))
            {
                canMove = NO;
                [self showExecuteErrorMessage:rtn];
            }
            
            if (canMove) {
                sender.enabled = NO;
                _isMoving = YES;
                
                __weak NSButton *button = sender;
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    if (0 != (rtn = smc_vmove(self->_controllerID, self->_selectedAxis, 0))) {
                        smc_stop(self->_controllerID, self->_selectedAxis, 0);
                        [self showExecuteErrorMessage:rtn];
                        self->_isMoving = NO;
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            button.enabled = YES;
                            [self appendMessage:[NSString stringWithFormat:@"Fail to move axis %d to origin", self->_selectedAxis] color:NSColor.darkGrayColor];
                        });
                    } else {
                        while (0 == smc_check_done(self->_controllerID, self->_selectedAxis)) { usleep(200000); }
                        
                        if (0 != (rtn = smc_home_move(self->_controllerID, self->_selectedAxis))) {
                            smc_stop(self->_controllerID, self->_selectedAxis, 0);
                            [self showExecuteErrorMessage:rtn];
                            self->_isMoving = NO;
                            
                            dispatch_async(dispatch_get_main_queue(), ^{
                                button.enabled = YES;
                                [self appendMessage:[NSString stringWithFormat:@"Fail to move axis %d to origin", self->_selectedAxis] color:NSColor.darkGrayColor];
                            });
                        } else {
                            WORD state;
                            do {
                                smc_get_home_result(self->_controllerID, self->_selectedAxis, &state);
                                usleep(100000);
                            } while (!state);
                            
                            self->_isMoving = NO;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                button.enabled = YES;
                                [self appendMessage:[NSString stringWithFormat:@"Success to move axis %d to origin", self->_selectedAxis] color:NSColor.darkGrayColor];
                            });
                        }
                    }
                });
            } else {
                sender.enabled = YES;
                [self appendMessage:[NSString stringWithFormat:@"Can't move axis %d because of some error happened", _selectedAxis] color:NSColor.redColor];
            }
        }
    }
}

- (IBAction)stopAxis:(NSButton *)sender {
    if (_connected) {
        int rtn = 0;
        if (0 == (rtn = smc_stop(_controllerID, _selectedAxis, 0))) {
            [self appendMessage:[NSString stringWithFormat:@"Stop axis %d", _selectedAxis] color:NSColor.blueColor];
        } else {
            [self showExecuteErrorMessage:rtn];
        }
    }
}

- (IBAction)calibrateAllAxis:(NSButton *)sender {
    if (_connected) {
        if ([sender.title isEqualToString:@"Run Calibration"]) {
            _isStopCalibrated = NO;
            [self appendMessage:@"Start calibration" color:NSColor.blueColor];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                self->_isMoving = true;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self appendMessage:@"Open auto-door" color:NSColor.darkGrayColor];
                });
                
                for (int axis = 1; axis <= 12; axis++) {
                    smc_stop(self->_controllerID, axis, 0);
                }
                // open door
                smc_write_outbit(self->_controllerID, 17, 0);
                smc_write_outbit(self->_controllerID, 18, 1);
                smc_write_outbit(self->_controllerID, 19, 0);
                smc_write_outbit(self->_controllerID, 20, 1);
                sleep(3);
                
                for (int axis = 1; axis <= 12; axis++) {
                    if (axis == self->_shieldAxis) {  // shield one axis.
                        continue;
                    }
                    
                    if (![self selfSingleAxis:axis]) {
                        break;
                    }
                }
                
                self->_isMoving = NO;
            });
            sender.title = @"Stop Calibration";
        } else {
            _isStopCalibrated = YES;
            sender.title = @"Run Calibration";
        }
    }
}

- (BOOL)selfSingleAxis:(int)axis {
    BOOL flag = true;
    int rtn = 0;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appendMessage:[NSString stringWithFormat:@"Start self-check axis %d", axis] color:NSColor.darkGrayColor];
    });
    
    do {
        if (0 != (rtn = smc_vmove(_controllerID, axis, 0))) {  // move to negative limit.
            smc_stop(_controllerID, axis, 0);
            [self showExecuteErrorMessage:rtn];
            flag = NO;
            break;
        } else {
            while (0 == smc_check_done(_controllerID, axis)) {
                if (_isStopCalibrated) {
                    flag = NO;
                    break;
                }
                usleep(200000);
            }
            
            if (0 != (rtn = smc_home_move(_controllerID, axis))) {
                smc_stop(_controllerID, axis, 0);
                [self showExecuteErrorMessage:rtn];
                flag = NO;
                break;
            } else {
                WORD state;
                while (0 == smc_get_home_result(_controllerID, axis, &state)) {
                    if (state) { break; }
                    if (_isStopCalibrated) {  flag = NO; break; }
                }
                
                if (0 != (rtn = smc_vmove(_controllerID, axis, 1))) {
                    smc_stop(_controllerID, axis, 0);
                    [self showExecuteErrorMessage:rtn];
                    flag = NO;
                    break;
                } else {
                    while (0 == smc_check_done(_controllerID, axis)) {
                        if (_isStopCalibrated) {
                            flag = NO;
                            break;
                        }
                        usleep(200000);
                    }
                    
                    if (axis == 1 || axis == 2 || axis == 3
                        || axis == 4 || axis == 11 || axis == 12) {
                        if (0 != (rtn = smc_pmove_unit(_controllerID, axis, 0, 1))) {
                            smc_stop(_controllerID, axis, 0);
                            [self showExecuteErrorMessage:rtn];
                            flag = NO;
                            break;
                        } else {
                            while (0 == smc_check_done(_controllerID, axis)) {
                                if (_isStopCalibrated) {
                                    flag = NO;
                                    break;
                                }
                                usleep(200000);
                            }
                        }
                    } else {
                        if (0 != (rtn = smc_vmove(_controllerID, axis, 0))) {
                            smc_stop(_controllerID, axis, 0);
                            [self showExecuteErrorMessage:rtn];
                            flag = NO;
                            break;
                        } else {
                            while (0 == smc_check_done(_controllerID, axis)) {
                                if (_isStopCalibrated) {
                                    flag = NO;
                                    break;
                                }
                                usleep(200000);
                            }
                        }
                    }
                    
                }
            }
        }
    } while (0);
    
    if (flag) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendMessage:[NSString stringWithFormat:@"Success to self-check axis %d", axis] color:NSColor.darkGrayColor];
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendMessage:[NSString stringWithFormat:@"Fail to self-check axis %d", axis] color:NSColor.redColor];
        });
    }
    return flag;
}

- (void)checkSensor {
    while (1) {
        if (!_connected || _selectedAxis <= 0) {
            sleep(1);
            continue;
        }
        
        DWORD errorcode = 0;
        nmcs_get_errcode(_controllerID, 2, &errorcode);
        
        if (errorcode != 0) {
            NSString *str = [NSString stringWithFormat:@"The bus error, errorcode: 0x%lx.", errorcode];
            NSAttributedString *attributeString = [[NSAttributedString alloc] initWithString:str
                                                                                  attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.failMsgText.textStorage appendAttributedString:attributeString];
                [self.failMsgText scrollPageDown:self];
            });
        }
        
        for (int axis = 1; axis <= 12; axis++) {
            DWORD state = smc_axis_io_status(_controllerID, axis);
            NSMutableDictionary *rowDict = self->_tableDataSource[axis-1];
            
            int sensorActivedCnt = 0;
            int index = 0;
            state <<= 1;
            
            do {
                state = state >> 1;
                int bit = state & 0x01;
                
                switch (index) {
                    case 0:
                        rowDict[_tableColumnIdentifier[4]] = @(bit);
                        if (bit) {
                            NSString *str = [self showErrorMessage:axis];
                            NSAttributedString *attributeString = [[NSAttributedString alloc] initWithString:str
                                                                                                  attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self.failMsgText.textStorage appendAttributedString:attributeString];
                                [self.failMsgText scrollPageDown:self];
                            });
                            sensorActivedCnt += 2;
                        }
                        break;
                    case 1:
                        rowDict[_tableColumnIdentifier[2]] = @(bit);
                        sensorActivedCnt += bit;
                        break;
                    case 2:
                        rowDict[_tableColumnIdentifier[1]] = @(bit);
                        sensorActivedCnt += bit;
                        break;
                    case 3:
                        rowDict[_tableColumnIdentifier[5]] = @(bit);
                        break;
                    case 4:
                        rowDict[_tableColumnIdentifier[3]] = @(bit);
                        sensorActivedCnt += bit;
                        break;
                    default:
                        break;
                }
                index++;
            } while (state);
            
            if (sensorActivedCnt >= 2) {
                rowDict[_tableColumnIdentifier[7]] = @"FAIL";
            } else {
                rowDict[_tableColumnIdentifier[7]] = @"PASS";
            }
            
            int rtn = 0;
            double position;
            if (0 == (rtn = smc_get_encoder_unit(_controllerID, axis, &position))) {
                NSDictionary *selectAxisParam = _axisParams[[NSString stringWithFormat:@"axis%d", axis]];
                double ppRatio = [selectAxisParam[@"pp_ratio"] doubleValue];
                position /= K_DEFAULT_ENCODER_RATIO;
                rowDict[_tableColumnIdentifier[6]] = @(position / ppRatio);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showExecuteErrorMessage:rtn];
                });
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
            usleep(50000);
        }
        
        if (_isMoving) {
            usleep(100000);
        } else {
            sleep(1);
        }
    }
}

- (NSString *)showErrorMessage:(int)axis {
    NSMutableString *errorMsg = [NSMutableString new];
    
    if (_controllerID != -1) {
        do {
            [errorMsg appendFormat:@"%@ Axis %d driver alarm. ", [self currentTimeString], axis];
            
            DWORD errorcode = 0;
            nmcs_get_errcode(_controllerID, 2, &errorcode);
            
            if (errorcode != 0) {
                [errorMsg appendFormat:@"The bus error, errorcode: 0x%lx.", errorcode];
                break;
            }
            
            nmcs_get_card_errcode(_controllerID, &errorcode);
            
            if (errorcode != 0) {
                [errorMsg appendFormat:@"The bus error, errorcode: 0x%lx.", errorcode];
                break;
            }
            
        } while (0);
    }
    
    [errorMsg appendString:@"\n"];
    
    return errorMsg;
}

- (void)showExecuteErrorMessage:(int)errorCode {
    static NSDictionary *kvErrors = nil;
    NSString *errorMessage = nil;
    
    if (!kvErrors) {
        NSString *path = [NSBundle.mainBundle pathForResource:@"ErrorCode" ofType:@"plist"];
        kvErrors = [NSDictionary dictionaryWithContentsOfFile:path];
    }
    
    if (kvErrors) {
        errorMessage =  kvErrors[[NSString stringWithFormat:@"%d", errorCode]];
        
        if (!errorMessage) {
            errorMessage = @"Unknown error";
        }
    } else {
        errorMessage = @"Unknown error";
    }
    
    NSString *str = nil;
    
    if (_selectedAxis > 0) {
        str = [NSString stringWithFormat:@"%@ Axis %d. %@\n", [self currentTimeString], _selectedAxis, errorMessage];
    } else {
        str = [NSString stringWithFormat:@"%@ %@\n", [self currentTimeString], errorMessage];
    }
    NSAttributedString *attributeString = [[NSAttributedString alloc] initWithString:str attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
    [self.failMsgText.textStorage appendAttributedString:attributeString];
    [self.failMsgText scrollPageDown:self];
}

- (void)appendMessage:(NSString *)message color:(NSColor *)color {
    NSString *str = [NSString stringWithFormat:@"%@ %@\n", [self currentTimeString], message];
    NSAttributedString *attributeString = [[NSAttributedString alloc] initWithString:str attributes:@{NSForegroundColorAttributeName : color}];
    [self.failMsgText.textStorage appendAttributedString:attributeString];
    [self.failMsgText scrollPageDown:self];
}

#pragma - mark TableView Delegate
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _tableDataSource.count;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 28;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *dict = _tableDataSource[row];
    NSTableCellView *view = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    [view.subviews[0] setFrame:view.bounds];
    
    if ([view.subviews[0] isKindOfClass:NSTextField.class]) {
        ((NSTextField *)view.subviews[0]).stringValue = [NSString stringWithFormat:@"%@", dict[tableColumn.identifier]];
        if ([tableColumn.identifier isEqualToString:@"fsc_status"]) {
            ((NSTextField *)view.subviews[0]).textColor = [dict[tableColumn.identifier] isEqualToString:@"FAIL"] ? NSColor.redColor : NSColor.greenColor;
        }
    } else if ([view.subviews[0] isKindOfClass:NSImageView.class]) {
        [(NSImageView *)view.subviews[0] setImageScaling:NSImageScaleProportionallyUpOrDown];
        int type = [dict[tableColumn.identifier] intValue];
        
        switch (type) {
            case 0:
                [((NSImageView *)view.subviews[0]) setImage:[NSImage imageNamed:@"grayLed.png"]];
                break;
            case 1:
                if ([tableColumn.identifier isEqualToString:@"fsc_emg"]
                    || [tableColumn.identifier isEqualToString:@"fsc_servo"]) {
                    [((NSImageView *)view.subviews[0]) setImage:[NSImage imageNamed:@"redLed.png"]];
                } else {
                    [((NSImageView *)view.subviews[0]) setImage:[NSImage imageNamed:@"greenLed.png"]];
                }
                break;
            case 2:
                [((NSImageView *)view.subviews[0]) setImage:[NSImage imageNamed:@"redLed.png"]];
                break;
            default:
                break;
        }
    }
    
    return view;
}

@end
