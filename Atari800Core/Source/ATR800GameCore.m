/*
 Copyright (c) 2011, OpenEmu Team
 
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


#import "ATR800GameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OE5200SystemResponderClient.h"
#import <OpenGL/gl.h>
#import <CommonCrypto/CommonDigest.h>

//#define _UINT32

#include "platform.h"
#include "memory.h"
#include "atari.h"
#include "config.h"
#include "monitor.h"
#include "log.h"
#ifdef SOUND
#include "sound.h"
#endif
#include "screen.h"
#include "colours.h"
#include "colours_ntsc.h"
#include "cfg.h"
#include "devices.h"
#include "input.h"
#include "rtime.h"
#include "sio.h"
#include "cassette.h"
#include "pbi.h"
#include "antic.h"
#include "gtia.h"
#include "pia.h"
#include "pokey.h"
#include "ide.h"
#include "cartridge.h"
#include "ui.h"
#include "akey.h"
#include "sysrom.h"
#include "statesav.h"
#include "pokeysnd.h"

typedef struct {
	int up;
	int down;
	int left;
	int right;
	int fire;
	int fire2;
	int start;
	int pause;
	int reset;
} ATR5200ControllerState;

@interface ATR800GameCore () <OE5200SystemResponderClient>
{
	unsigned char *screenBuffer;
    unsigned char *soundBuffer;
    double sampleRate;
	ATR5200ControllerState controllerStates[4];
    NSString *md5Hash;
}
- (void)renderToBuffer;
- (ATR5200ControllerState)controllerStateForPlayer:(NSUInteger)playerNum;
int Atari_POT(int);
int16_t convertSample(uint8_t);
@end

static ATR800GameCore *currentCore;

//void ATR800WriteSoundBuffer(uint8_t *buffer, unsigned int len);

static int num_cont = 4;

#pragma mark - atari800 platform calls

int PLATFORM_Initialise(int *argc, char *argv[])
{
#ifdef SOUND
	Sound_Initialise(argc, argv);
#endif
    
    if (Sound_enabled) {
		/* Up to this point the Sound_enabled flag indicated that we _want_ to
         enable sound. From now on, the flag will indicate whether audio
         output is enabled and working. So, since the sound output was not
         yet initiated, we set the flag accordingly. */
		Sound_enabled = FALSE;
		/* Don't worry, Sound_Setup() will set Sound_enabled back to TRUE if
         it opens audio output successfully. But Sound_Setup() relies on the
         flag being set if and only if audio output is active. */
		if (Sound_Setup())
        /* Start sound if opening audio output was successful. */
            Sound_Continue();
	}
    
    POKEYSND_stereo_enabled = TRUE;
	
	return TRUE;
}

int PLATFORM_Exit(int run_monitor)
{
	Log_flushlog();
	
	if (run_monitor && MONITOR_Run())
		return TRUE;
	
#ifdef SOUND
	Sound_Exit();
#endif
	
	return FALSE;
}

// believe these are used for joystick/input or something
// they get called off of the frame call
int PLATFORM_PORT(int num)
{
	if(num < 4 && num >= 0) {
		ATR5200ControllerState state = [currentCore controllerStateForPlayer:num];
		if(state.up == 1 && state.left == 1) {
			return INPUT_STICK_UL;
		}
		else if(state.up == 1 && state.right == 1) {
			return INPUT_STICK_UR;
		}
		else if(state.up == 1) {
			//NSLog(@"UP");
			return INPUT_STICK_FORWARD;
		}
		else if(state.down == 1 && state.left == 1) {
			return INPUT_STICK_LL;
		}
		else if(state.down == 1 && state.right == 1) {
			//NSLog(@"Left-right");
			return INPUT_STICK_LR;
		}
		else if(state.down == 1) {
			//NSLog(@"DOWN");
			return INPUT_STICK_BACK;
		}
		else if(state.left == 1) {
			//NSLog(@"Left");
			return INPUT_STICK_LEFT;
		}
		else if(state.right == 1) {
			//NSLog(@"Right");
			return INPUT_STICK_RIGHT;
		}
		return INPUT_STICK_CENTRE;
	}
	return 0xff;
}

int PLATFORM_TRIG(int num)
{
	if(num < 4 && num >= 0) {
		ATR5200ControllerState state = [currentCore controllerStateForPlayer:num];
		if(state.fire == 1) {
			//NSLog(@"Pew pew");
		}
		return state.fire == 1 ? 0 : 1;
	}
	return 1;
}

// Looks to be called when the atari UI is on screen
// in ui.c & ui_basic.c
int PLATFORM_Keyboard(void)
{
	return 0;
}

// maybe we can update our RGB buffer in this?
void PLATFORM_DisplayScreen(void)
{
}

int Atari_POT(int num)
{
	int val;
//	cont_cond_t *cond;
	
	if (Atari800_machine_type != Atari800_MACHINE_5200) {
		if (0 /*emulate_paddles*/) {
//			if (num + 1 > num_cont) return(228);
//			
//			cond = &mcond[num];
//			val = cond->joyx;
//			val = val * 228 / 255;
//			if (val > 227) return(1);
//			return(228 - val);
		}
		else {
			return(228);
		}
	}
	else {	/* 5200 version:
			 *
			 * num / 2: which controller
			 * num & 1 == 0: x axis
			 * num & 1 == 1: y axis
			 */
		
		if (num / 2 + 1 > num_cont) return(INPUT_joy_5200_center);
		ATR5200ControllerState state = [currentCore controllerStateForPlayer:(num/2)];
//		cond = &mcond[num / 2];
		if(num & 1) { // y-axis
			if(state.up)
				val = 255;
			else if(state.down)
				val = 0;
			else
				val = 127;
		}
		else { // x-axis
			if(state.right)
				val = 255;
			else if(state.left)
				val = 0;
			else
				val = 127;
		}
//		val = (num & 1) ? cond->joyy : cond->joyx;
		
		/* normalize into 5200 range */
		//NSLog(@"joystick value: %i", val);
		if (val == 127) return(INPUT_joy_5200_center);
		if (val < 127) {
			/*val -= INPUT_joy_5200_min;*/
			val = val * (INPUT_joy_5200_center - INPUT_joy_5200_min) / 127;
			return(val + INPUT_joy_5200_min);
		}
		else {
			val = val * INPUT_joy_5200_max / 255;
			if (val < INPUT_joy_5200_center)
				val = INPUT_joy_5200_center;
			return(val);
		}
	}
}

int PLATFORM_SoundSetup(Sound_setup_t *setup)
{
    int buffer_samples;
    
    if (setup->frag_frames == 0) {
		/* Set frag_frames automatically. */
		unsigned int val = setup->frag_frames = setup->freq / 50;
		unsigned int pow_val = 1;
		while (val >>= 1)
			pow_val <<= 1;
		if (pow_val < setup->frag_frames)
			pow_val <<= 1;
		setup->frag_frames = pow_val;
	}
    
    setup->sample_size = 2;
    
    buffer_samples = setup->frag_frames * setup->channels;
    setup->frag_frames = buffer_samples / setup->channels;
    
    return TRUE;
}

void PLATFORM_SoundExit(void){}

void PLATFORM_SoundPause(void){}

void PLATFORM_SoundContinue(void){}

//int16_t convertSample(uint8_t sample)
//{
//	float floatSample = (float)sample / 255;
//	return (int16_t)(floatSample * 65535 - 32768);
//}
//
//void ATR800WriteSoundBuffer(uint8_t *buffer, unsigned int len) {
//	int samples = len / sizeof(uint8_t);
//	NSUInteger newLength = len * sizeof(int16_t);
//	int16_t *newBuffer = malloc(len * sizeof(int16_t));
//	int16_t *dest = newBuffer;
//	uint8_t *source = buffer;
//	for(int i = 0; i < samples; i++) {
//		*dest = convertSample(*source);
//		dest++;
//		source++;
//	}
//    [[currentCore ringBufferAtIndex:0] write:newBuffer maxLength:newLength];
//	free(newBuffer);
//}

@implementation ATR800GameCore

- (id)init
{
    if((self = [super init]))
    {
        screenBuffer = malloc(Screen_WIDTH * Screen_HEIGHT * 4);
        soundBuffer = malloc(2048); // 4096 if stereo?
    }
    
    currentCore = self;
    
    return self;
}

- (void)dealloc
{
	Atari800_Exit(false);
	free(screenBuffer);
    free(soundBuffer);
	[super dealloc];
}

- (void)executeFrame
{
//	NSLog(@"Executing");
	// Note: this triggers UI code and also calls the input functions above
	Atari800_Frame();
    
    int size = 44100 / (Atari800_tv_mode == Atari800_TV_NTSC ? 60 : 50) * 2;
    
    Sound_Callback(soundBuffer, size);
    
    //NSLog(@"Sound_desired.channels %d frag_frames %d freq %d sample_size %d", Sound_desired.channels, Sound_desired.frag_frames, Sound_desired.freq, Sound_desired.sample_size);
    //NSLog(@"Sound_out.channels %d frag_frames %d freq %d sample_size %d", Sound_out.channels, Sound_out.frag_frames, Sound_out.freq, Sound_out.sample_size);
    
    [[currentCore ringBufferAtIndex:0] write:soundBuffer maxLength:size];
    
	[self renderToBuffer];
}

- (void)setupEmulation
{
//	int ac = 1;
//	char av = '\0';
//	char *avp = &av;
//    
//	if (!Atari800_Initialise(&ac, &avp))
//		NSLog(@"Failed to initialize Atari800 emulation");
}

- (ATR5200ControllerState)controllerStateForPlayer:(NSUInteger)playerNum
{
	ATR5200ControllerState state = {0,0,0,0,0,0,0,0};
	if(playerNum < 4) {
		state = controllerStates[playerNum];
	}
	return state;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    //Get the size of the rom so that Atari800 knows which 5200 cart type to load
    NSData* dataObj = [NSData dataWithContentsOfFile:[path stringByStandardizingPath]];
    size_t size = [dataObj length];
    
    // Compute md5 hash
    unsigned char hash[16];
    CC_MD5([dataObj bytes], (CC_LONG)size, hash);
    md5Hash = [NSString stringWithFormat:
               @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
               hash[0], hash[1], hash[2], hash[3],
               hash[4], hash[5], hash[6], hash[7],
               hash[8], hash[9], hash[10], hash[11],
               hash[12], hash[13], hash[14], hash[15]
               ];

    DLog(@"Loadeding File: ", path);
    
    char biosFileName[2048];
    NSString *biosPath = [self biosDirectoryPath];
    
    strcpy(biosFileName, [[biosPath stringByAppendingPathComponent:@"5200.rom"] UTF8String]);
    
    // set the default palette
    NSString *palettePath = [[[NSBundle bundleForClass:[self class]] resourcePath] stringByAppendingPathComponent:@"Default.act"];
    strcpy(COLOURS_NTSC_external.filename, [palettePath UTF8String]);
    COLOURS_NTSC_external.loaded = TRUE;
	
    Atari800_tv_mode = Atari800_TV_NTSC;
    
	Colours_PreInitialise();
	
    // set 5200.rom BIOS path
    SYSROM_SetPath(biosFileName, 3, SYSROM_5200);
	
    // setup what machine
	Atari800_machine_type = Atari800_MACHINE_5200;
	MEMORY_ram_size = 16;

	int test = 0;
	int *argc = &test;
	char *argv[] = {};
	if (
#if !defined(BASIC) && !defined(CURSES_BASIC)
		!Colours_Initialise(argc, argv) ||
#endif
		!Devices_Initialise(argc, argv)
		|| !RTIME_Initialise(argc, argv)
#ifdef IDE
		|| !IDE_Initialise(argc, argv)
#endif
		|| !SIO_Initialise (argc, argv)
		|| !CASSETTE_Initialise(argc, argv)
		|| !PBI_Initialise(argc,argv)
#ifdef VOICEBOX
		|| !VOICEBOX_Initialise(argc, argv)
#endif
#ifndef BASIC
		|| !INPUT_Initialise(argc, argv)
#endif
#ifdef XEP80_EMULATION
		|| !XEP80_Initialise(argc, argv)
#endif
#ifdef AF80
		|| !AF80_Initialise(argc, argv)
#endif
#ifdef NTSC_FILTER
		|| !FILTER_NTSC_Initialise(argc, argv)
#endif
#if SUPPORTS_CHANGE_VIDEOMODE
		|| !VIDEOMODE_Initialise(argc, argv)
#endif
#ifndef DONT_DISPLAY
		/* Platform Specific Initialisation */
		|| !PLATFORM_Initialise(argc, argv)
#endif
		|| !Screen_Initialise(argc, argv)
		/* Initialise Custom Chips */
		|| !ANTIC_Initialise(argc, argv)
		|| !GTIA_Initialise(argc, argv)
		|| !PIA_Initialise(argc, argv)
		|| !POKEY_Initialise(argc, argv)
		) {
		NSLog(@"Failed to initialize part of atari800");
		return NO;
	}
	
	// this gets called again, maybe we can skip this first one?
	if(!Atari800_InitialiseMachine()) {
		NSLog(@"** Failed to initialize machine");
		return NO;
	}
	
	/* Install requested ROM cartridge */
	if (path) {
		int r = CARTRIDGE_Insert([path UTF8String]);
		if (r < 0) {
			Log_print("Error inserting cartridge \"%s\": %s", [path UTF8String],
					  r == CARTRIDGE_CANT_OPEN ? "Can't open file" :
					  r == CARTRIDGE_BAD_FORMAT ? "Bad format" :
					  r == CARTRIDGE_BAD_CHECKSUM ? "Bad checksum" :
					  "Unknown error");
		}
		if (r > 0) {
#ifdef BASIC
			Log_print("Raw cartridge images not supported in BASIC version!");
#else /* BASIC */
			
#ifndef __PLUS
//			UI_is_active = TRUE;
//			CARTRIDGE_type = UI_SelectCartType(r);
//			UI_is_active = FALSE;

            NSLog(@"Cart size: %zd", size >> 10);
            
            NSArray *One_Chip_16KB = @[@"a47fcb4eedab9418ea098bb431a407aa", // A.E. (Proto)
                                       @"45f8841269313736489180c8ec3e9588", // Activision Decathlon, The
                                       @"1913310b1e44ad7f3b90aeb16790a850", // Beamrider
                                       @"f8973db8dc272c2e5eb7b8dbb5c0cc3b", // BerZerk
                                       @"e0b47a17fa6cd9d6addc1961fca43414", // Blaster
                                       @"8123393ae9635f6bc15ddc3380b04328", // Blue Print
                                       @"3ff7707e25359c9bcb2326a5d8539852", // Choplifter!
                                       @"7c27d225a13e178610babf331a0759c0", // David Crane's Pitfall II - Lost Caverns
                                       @"2bb63d65efc8682bc4dfac0fd0a823be", // Final Legacy (Proto)
                                       @"f8f0e0a6dc2ffee41b2a2dd736cba4cd", // H.E.R.O.
                                       @"46264c86edf30666e28553bd08369b83", // Last Starfighter, The (Proto)
                                       @"1cd67468d123219201702eadaffd0275", // Meteorites
                                       @"84d88bcdeffee1ab880a5575c6aca45e", // Millipede (Proto)
                                       @"d859bff796625e980db1840f15dec4b5", // Miner 2049er Starring Bounty Bob
                                       @"296e5a3a9efd4f89531e9cf0259c903d", // Moon Patrol
                                       @"099706cedd068aced7313ffa371d7ec3", // Quest for Quintana Roo
                                       @"5dba5b478b7da9fd2c617e41fb5ccd31", // Robotron 2084
                                       @"802a11dfcba6229cc2f93f0f3aaeb3aa", // Space Shuttle - A Journey Into Space
                                       @"7dab86351fe78c2f529010a1ac83a4cf", // Super Pac-Man (Proto)
                                       @"496b6a002bc7d749c02014f7ec6c303c", // Tempest (Proto)
                                       @"33053f432f9c4ad38b5d02d1b485b5bd", // Track and Field (Proto)
                                       @"560b68b7f83077444a57ebe9f932905a", // Wizard of Wor
                                       @"dc45af8b0996cb6a94188b0be3be2e17"  // Zone Ranger
                                       ];
            
            NSArray *Two_Chip_16KB = @[@"bae7c1e5eb04e19ef8d0d0b5ce134332", // Astro Chase
                                       @"78ccbcbb6b4d17b749ebb012e4878008", // Atari PAM Diagnostics (v2.0)
                                       @"32a6d0de4f1728dee163eb2d4b3f49f1", // Atari PAM Diagnostics (v2.3)
                                       @"8576867c2cfc965cf152be0468f684a7", // Battlezone (Proto)
                                       @"a074a1ff0a16d1e034ee314b85fa41e9", // Buck Rogers - Planet of Zoom
                                       @"261702e8d9acbf45d44bb61fd8fa3e17", // Centipede
                                       @"5720423ebd7575941a1586466ba9beaf", // Congo Bongo
                                       @"1a64edff521608f9f4fa9d7bdb355087", // Countermeasure
                                       @"27d5f32b0d46d3d80773a2b505f95046", // Defender
                                       @"3abd0c057474bad46e45f3d4e96eecee", // Dig Dug
                                       @"14bd9a0423eafc3090333af916cfbce6", // Frisky Tom (Proto)
                                       @"d8636222c993ca71ca0904c8d89c4411", // Frogger II - Threeedeep!
                                       @"dacc0a82e8ee0c086971f9d9bac14127", // Gyruss
                                       @"936db7c08e6b4b902c585a529cb15fc5", // James Bond 007
                                       @"25cfdef5bf9b126166d5394ae74a32e7", // Joust
                                       @"bc748804f35728e98847da6cdaf241a7", // Jr. Pac-Man (Proto)
                                       @"834067fdce5d09b86741e41e7e491d6c", // Jungle Hunt
                                       @"796d2c22f8205fb0ce8f1ee67c8eb2ca", // Kangaroo
                                       @"d0a1654625dbdf3c6b8480c1ed17137f", // Looney Tunes Hotel (Proto)
                                       @"24348dd9287f54574ccc40ee40d24a86", // Microgammon SB (Proto)
                                       @"69d472a79f404e49ad2278df3c8a266e", // Miniature Golf (Proto)
                                       @"694897cc0d98fcf2f59eef788881f67d", // Montezuma's Revenge featuring Panama Joe
                                       @"ef9a920ffdf592546499738ee911fc1e", // Ms. Pac-Man
                                       @"f1a4d62d9ba965335fa13354a6264623", // Pac-Man
                                       @"fd0cbea6ad18194be0538844e3d7fdc9", // Pole Position
                                       @"dd4ae6add63452aafe7d4fa752cd78ca", // Popeye
                                       @"9b7d9d874a93332582f34d1420e0f574", // Qix
                                       @"a71bfb11676a4e4694af66e311721a1b", // RealSports Basketball (82-11-05) (Proto)
                                       @"022c47b525b058796841134bb5c75a18", // RealSports Football
                                       @"3074fad290298d56c67f82e8588c5a8b", // RealSports Soccer
                                       @"7e683e571cbe7c77f76a1648f906b932", // RealSports Tennis
                                       @"ddf7834a420f1eaae20a7a6255f80a99", // Road Runner (Proto)
                                       @"6e24e3519458c5cb95a7fd7711131f8d", // Space Dungeon
                                       @"993e3be7199ece5c3e03092e3b3c0d1d", // Sport Goofy (Proto)
                                       @"e2d3a3e52bb4e3f7e489acd9974d68e2", // Star Raiders
                                       @"c959b65be720a03b5479650a3af5a511", // Star Trek - Strategic Operations Simulator
                                       @"00beaa8405c7fb90d86be5bb1b01ea66", // Star Wars - The Arcade Game
                                       @"595703dc459cd51fed6e2a191c462969", // Stargate (Proto)
                                       @"4f6c58c28c41f31e3a1515fe1e5d15af"  // Xari Arena (Proto)
                                       ];
            BOOL is16KBOneChip;
            is16KBOneChip = NO;
            
            //Tell Atari800 which 5200 cart type to load based on size
            switch (size >> 10) {
                case 40:
                    //CARTRIDGE_SetType
                    CARTRIDGE_main.type = CARTRIDGE_5200_40; //bounty bob strikes back
                    break;
                case 32:
                    CARTRIDGE_main.type = CARTRIDGE_5200_32;
                    break;
                case 16:
                    // Determine if 16KB cart is one-chip (NS_16) or two-chip (EE_16)
                    for (NSString* hash in One_Chip_16KB)
                    {
                        if ([md5Hash isEqualToString:hash])
                        {
                            is16KBOneChip = YES;
                            break;
                        }
                    }
                    if (is16KBOneChip) CARTRIDGE_main.type = CARTRIDGE_5200_NS_16;
                    else CARTRIDGE_main.type = CARTRIDGE_5200_EE_16;
                    break;
                case 8:
                    CARTRIDGE_main.type = CARTRIDGE_5200_8;
                    break;
                case 4:
                    CARTRIDGE_main.type = CARTRIDGE_5200_4;
                    break;
            }
            
#else /* __PLUS */
			CARTRIDGE_main.type = (CARTRIDGE_NONE == nCartType ? UI_SelectCartType(r) : nCartType);
#endif /* __PLUS */
			CARTRIDGE_ColdStart();
			
#endif /* BASIC */
		}
#ifndef __PLUS
		if (CARTRIDGE_main.type != CARTRIDGE_NONE) {
			//int for5200 = CARTRIDGE_IsFor5200(CARTRIDGE_main.type);
			//if (for5200 && Atari800_machine_type != Atari800_MACHINE_5200) {
            if (Atari800_machine_type != Atari800_MACHINE_5200) {
				Atari800_machine_type = Atari800_MACHINE_5200;
				MEMORY_ram_size = 16;
				Atari800_InitialiseMachine();
			}
			//else if (!for5200 && Atari800_machine_type == Atari800_MACHINE_5200) {
			//	Atari800_machine_type = Atari800_MACHINE_XLXE;
			//	MEMORY_ram_size = 64;
			//	Atari800_InitialiseMachine();
			//}
		}
#endif /* __PLUS */
	}
    
    //POKEYSND_Init(POKEYSND_FREQ_17_EXACT, 44100, 1, POKEYSND_BIT16);

    return YES;
}
- (void)resetEmulation
{
	Atari800_Coldstart();
}

- (void)stopEmulation
{
//	Atari800_Exit(false);
    [super stopEmulation];
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(Screen_WIDTH, Screen_HEIGHT);
}

- (const void *)videoBuffer
{
    return screenBuffer;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

- (double)audioSampleRate
{
    return 44100;
}

- (NSTimeInterval)frameInterval
{
    return Atari800_tv_mode == Atari800_TV_NTSC ? Atari800_FPS_NTSC : Atari800_FPS_PAL;
}

- (NSUInteger)channelCount
{
    return 1;
}


- (BOOL)saveStateToFileAtPath:(NSString *)fileName
{
    return StateSav_SaveAtariState([fileName UTF8String], "wb", TRUE) ? YES : NO;
}

- (BOOL)loadStateFromFileAtPath:(NSString *)fileName
{
    return StateSav_ReadAtariState([fileName UTF8String], "rb") ? YES : NO;
}

#pragma mark -
//Think this is converting to 32-bit BGRA
- (void)renderToBuffer
{
	int i, j;
	UBYTE *source = (UBYTE *)(Screen_atari);
	UBYTE *destination = screenBuffer;
	for (i = 0; i < Screen_HEIGHT; i++) {
//		printf("ROW-%i", i);
		for (j = 0; j < Screen_WIDTH; j++) {
			UBYTE r,g,b;
			r = Colours_GetR(*source);
			g = Colours_GetG(*source);
			b = Colours_GetB(*source);
			*destination++ = b;
			*destination++ = g;
			*destination++ = r;
			*destination++ = 0xff;
			source++;
//			printf(",%u", *source);
		}
//		source += Screen_WIDTH - ATARI_VISIBLE_WIDTH;
//		printf("\n");
	}
//	NSLog(@"Done render");
}

#pragma mark - Input handling

- (oneway void)didPush5200Button:(OE5200Button)button forPlayer:(NSUInteger)player
{
	player--;
	//NSLog(@"Pressed: %i", button);
	switch (button) {
		case OE5200ButtonFire1:
			controllerStates[player].fire = 1;
			break;
        case OE5200ButtonFire2:
			//controllerStates[player].fire2 = 1;
            INPUT_key_shift = 1; //AKEY_SHFTCTRL
			break;
		case OE5200ButtonUp:
			controllerStates[player].up = 1;
            //INPUT_key_code = AKEY_UP ^ AKEY_CTRL;
            //INPUT_key_code = INPUT_STICK_FORWARD;
			break;
		case OE5200ButtonDown:
			controllerStates[player].down = 1;
			break;
		case OE5200ButtonLeft:
			controllerStates[player].left = 1;
			break;
		case OE5200ButtonRight:
			controllerStates[player].right = 1;
			break;
		case OE5200ButtonStart:
//			controllerStates[player].start = 1;
			INPUT_key_code = AKEY_5200_START;
			break;
        case OE5200ButtonPause:
            INPUT_key_code = AKEY_5200_PAUSE;
            break;
        case OE5200ButtonReset:
            INPUT_key_code = AKEY_5200_RESET;
		default:
			break;
	}
}

- (oneway void)didRelease5200Button:(OE5200Button)button forPlayer:(NSUInteger)player
{
    player--;
    //NSLog(@"Released: %i", button);
    switch (button) {
        case OE5200ButtonFire1:
            controllerStates[player].fire = 0;
            break;
        case OE5200ButtonFire2:
            //controllerStates[player].fire2 = 0;
            INPUT_key_shift = 0;
            break;
        case OE5200ButtonUp:
            controllerStates[player].up = 0;
            //INPUT_key_code = 0xff;
            break;
        case OE5200ButtonDown:
            controllerStates[player].down = 0;
            break;
        case OE5200ButtonLeft:
            controllerStates[player].left = 0;
            break;
        case OE5200ButtonRight:
            controllerStates[player].right = 0;
            break;
        case OE5200ButtonStart:
            //			controllerStates[player].start = 1;
            INPUT_key_code = AKEY_NONE;
            break;
        case OE5200ButtonPause:
            INPUT_key_code = AKEY_NONE;
            break;
        case OE5200ButtonReset:
            INPUT_key_code = AKEY_NONE;
        default:
            break;
    }
}

@end
