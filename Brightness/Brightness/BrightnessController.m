//
//  BrightnessController.m
//  Brightness
//
//  Created by Kevin on 3/3/15.
//  Copyright (c) 2015 Kevin. All rights reserved.
//

#import "BrightnessController.h"
#import "DDC.h"

const int maxDisplays=1000;


@implementation BrightnessController


- (CGError) getBrightness: (float*) storeResultIn
{
    
    io_iterator_t iterator;
    kern_return_t result = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                        IOServiceMatching("IODisplayConnect"),
                                                        &iterator);
    
    float sum=0;
    int count=0;
    // If we were successful
    if (result == kIOReturnSuccess)
    {
        io_object_t service;
        while ((service = IOIteratorNext(iterator))) {
            float brightness;
            CFDictionaryRef ref = IODisplayCreateInfoDictionary(service, kNilOptions);
            NSDictionary *andBack = (__bridge NSDictionary*)ref;
            NSLog(@"%@", andBack);
            result = IODisplayGetFloatParameter(service, kNilOptions, CFSTR(kIODisplayBrightnessKey), &brightness);
            if (result == kIOReturnSuccess)
            {
                count++;
                sum+=brightness;
                printf("%d: %f\n", count, brightness);
            }
            // Let the object go
            IOObjectRelease(service);
        }
    }
    printf("%d brightnesses\n", count);
    if(count>0){
        *storeResultIn = sum/count;
        return 0;
    }
    return 1;
}

- (NSString *) displayStr:(CGDirectDisplayID) display{
    return [NSString stringWithFormat:@"%d", (int)display];
}

- (NSMutableDictionary*) getDisplayGammaTableMapping{
    
    NSMutableDictionary * dict = [NSMutableDictionary dictionary];
    const int maxDisplays=1000;
    
    CGDirectDisplayID activeDisplays[maxDisplays];
    uint32_t n_active_displays;
    CGError err = CGGetActiveDisplayList (maxDisplays, activeDisplays, &n_active_displays );
    if(!err){
        for(int i=0;i<n_active_displays;i++){
            CGDirectDisplayID display = activeDisplays[i];
            GammaTable * table = [GammaTable tableForDisplay:display];
            if(table){
                [dict setValue:table forKey:[self displayStr:display]];
                
            }
        }
    }
    return dict;
}

-(id) init{
    self = [super init];
    
    return self;
}

- (void) start{
    self.targetBrightness=1.0;
    self.lastReinitializedAt = 0.0;
    self.reinitializeOnNextRefresh = false;
    [self reinitialize: @"Just starting up"];
    
}



- (void) reinitialize: (NSString*) info{
    NSLog(@"Reinitializing: %@\n", info);
    
    
    CGDisplayRestoreColorSyncSettings();
    
    //self.dict = [self getDisplayGammaTableMapping]; //remove soon
    //self.lastCheckedActiveDisplays = [BrightnessController getActiveDisplays];
    self.displayCollection = [DisplayCollection makeFromCurrentlyActiveDisplays];
    self.drivingDisplay = [self searchForDrivingDisplay];
    

    
    [self updateAllDisplaysWithMeticulousness:YES];
    NSTimeInterval time_now = [[NSProcessInfo processInfo] systemUptime];
    self.lastReinitializedAt = time_now;
    self.reinitializeOnNextRefresh = false;
}

//A notification named NSApplicationDidChangeScreenParametersNotification. Calling the object method of this notification returns the NSApplication object itself.
-(void) applicationDidChangeScreenParameters:(NSNotification*) notification{
    
    //Check if the display list actually changed, don't do anything if no change.
    
    
    DisplayCollection * newDisplayCollection =[DisplayCollection makeFromCurrentlyActiveDisplays];
    BOOL somethingChanged = false;
    if([newDisplayCollection.displays count] != [self.displayCollection.displays count]){
        somethingChanged = true;
    }else{
        for(int i=0;i<[newDisplayCollection.displays count];i++){
            DisplayInfo * theOld = self.displayCollection.displays[i];
            DisplayInfo * theNew = newDisplayCollection.displays[i];
            if(theOld.displayID != theNew.displayID){
                somethingChanged = true;
                break;
            }
        }
    }
    if(somethingChanged){
        [self reinitialize: notification.name];
    }else{
        NSLog(@"Got display config changed notification, but nothing really changed... Not reintializing.");
    }
    
}

- (void) receiveWakeNote: (NSNotification*) note{
    //NSLog(@"receiveWakeNote: %@", [note name]);
    [self reinitialize: note.name];
}

+ (NSArray*) getActiveDisplays{
    CGDirectDisplayID activeDisplays[maxDisplays];
    uint32_t n_active_displays;
    
    NSMutableArray * arr = [NSMutableArray array];
    
    CGError err = CGGetActiveDisplayList (maxDisplays, activeDisplays, &n_active_displays );
    if(!err){
        for(int i=0;i<n_active_displays;i++){
            arr[i] = @(activeDisplays[i]);
        }
    }
    return arr;
}

- (GammaTable *) origGammaTableForDisplay:(CGDirectDisplayID) display{
    if(self.dict){
        GammaTable * origTable = [self.dict objectForKey:[self displayStr:display]];
        if(origTable){
            return origTable;
        }
    }
    return nil;
}

- (DisplayInfo *) searchForDrivingDisplay{
    for (DisplayInfo * info in self.displayCollection.displays){
    NSLog(@"Test display is %@, %@", info.description, info.displayName);
        NSLog(@"Can read brightness %d", info.canReadRealBrightness);
        NSLog(@"Can set brightness %d", info.canSetRealBrightness);
    }
    for (DisplayInfo * info in self.displayCollection.displays){
     
        if(info.canReadRealBrightness){
            NSLog(@"Active display is %@, %@", info.description, info.displayName);
            return info;
        }
    }
    return nil;
}



- (void) updateAllDisplaysWithMeticulousness: (BOOL) meticulous{
    [self updateTargetBrightness];
    uint target = self.targetBrightness * 100;
    NSLog(@"Setting brightness %d", target);
    for (DisplayInfo * dispInfo in self.displayCollection.displays){
        @try{
            if(dispInfo == self.drivingDisplay){
                // dont set brightness of driving display
                continue;
            }
            if(dispInfo.canSetRealBrightness){
                // assume the brightness of a display where real brightness can be set doesn't need synching.
            }else{
                uint current = getDDCBrightness(dispInfo.displayID);
                NSLog(@"Current brightness %d", current);
                if(meticulous || abs((int)target - (int)current) > 1){
                    NSLog(@"Setting real brightness to %d", target);
                    setDDCBrightness(dispInfo.displayID, target);
                }
            }
        }
        @catch ( NSException *e ) {
            NSLog(@"Error updating brightness on display %d - %@", dispInfo.displayID, dispInfo.displayName);
        }
    }
}

void setDDCBrightness(CGDirectDisplayID displayID, float brightness){
    struct DDCWriteCommand command;
    command.control_id = BRIGHTNESS;
    command.new_value = brightness;
    if (!DDCWrite(displayID, &command)) {
        NSLog(@"E: Failed to send DDC brightness command!");
    }
}

uint getDDCBrightness(CGDirectDisplayID displayID) {
    struct DDCReadCommand command;
    command.control_id = BRIGHTNESS;
    command.max_value = 0;
    command.current_value = 0;
    if (!DDCRead(displayID, &command)){
        NSLog(@"E: DDC Read failed");
    }
    return command.current_value;
    
}

- (void) updateTargetBrightness{
    if(self.drivingDisplay){
        if(CGDisplayIsActive(self.drivingDisplay.displayID)){
            float b=self.targetBrightness;
            int failed=0;
            @try{
                b = [self.drivingDisplay getRealBrightness]; // throws
            }
            @catch ( NSException *e ) {
                NSLog(@"Error getting brightness %@", e);
                failed=1;
                self.reinitializeOnNextRefresh = true;
            }
            if(!failed){
                self.targetBrightness = b;
            }
        }else{
            NSLog(@"Driving display is asleep -- it should be removed very soon -- keeping old brightness");
        }
    }else{
        NSLog(@"No driving display -- keeping old brightness");
    }
}

- (void) refresh{
    if(self.reinitializeOnNextRefresh){
        [self reinitialize:@"Last refresh failed"];
        return;
    }
    BOOL meticulous;
    NSTimeInterval time_now = [[NSProcessInfo processInfo] systemUptime];
    if(time_now - self.lastReinitializedAt < 6.0){
        meticulous = YES;
    }else{
        meticulous = NO;
    }
    [self updateAllDisplaysWithMeticulousness:meticulous];
    /*
    float builtInBrightness=1;
    CGError err = 0;
    //err = [self getBrightness: &builtInBrightness];
    NSArray * displays = [BrightnessController getActiveDisplays];
    for (id displayVal in displays){
        
        CGDirectDisplayID display = [displayVal intValue];
        [DisplayInfo makeForDisplay:display];
        float brightness;
        err = getBrightnessForDisplay(display, &brightness);
        if(!err){
            builtInBrightness = brightness;
            printf("Got brightness %f for display %d\n", brightness, (int)display);
        }else{
            puts("Error reading brightness");
        }
    }

    //CGDisplayRestoreColorSyncSettings();
    
    
    for (id displayVal in displays){
        //CGDirectDisplayID display = nil;
        CGDirectDisplayID display = [displayVal intValue];
        if(!CGDisplayIsBuiltin(display)){
            //setDisplayBrightness(display, builtInBrightness);
            GammaTable * origTable = [self origGammaTableForDisplay:display];
            GammaTable * darker = [origTable copyWithBrightness:builtInBrightness];
            [darker applyToDisplay:display];
        }
    }
    */
}

@end
