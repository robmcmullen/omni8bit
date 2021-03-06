
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "atari800_bridge.h"

#include "libdebugger.h"

#include "atari.h"
#include "afile.h"
#include "akey.h"
#include "log.h"
#include "input.h"
#include "platform.h"
#include "cpu.h"
#include "memory.h"
#include "screen.h"
#include "sio.h"
#ifdef SOUND
#include "sound.h"
#endif
#include "util.h"

/* mainloop includes */
#include "antic.h"
#include "devices.h"
#include "gtia.h"
#include "pokey.h"
#ifdef PBI_BB
#include "pbi_bb.h"
#endif
#if defined(PBI_XLD) || defined (VOICEBOX)
#include "votraxsnd.h"
#endif

#include "libatari800/main.h"
#include "libatari800/init.h"
#include "libatari800/input.h"
#include "libatari800/video.h"
#include "libatari800/statesav.h"
#include "libatari800/libatari800.h"

#include "tinycthread.h"

static int threading_status = thrd_error;
mtx_t calculating_frame;
cnd_t talking_stick;
thrd_t frame_thread;

breakpoints_t *LIBATARI800_Breakpoints = NULL;
frame_status_t *LIBATARI800_Status = NULL;
emulator_history_t *LIBATARI800_History = NULL;
uint8_t *memory_access;
uint8_t *access_type;

int threaded_frame(void *arg);


/***** Initialization functions *****/

int init_thread() {
	int err;

	err = mtx_init(&calculating_frame, mtx_plain);
	if (err == thrd_success) {
		err = cnd_init(&talking_stick);
	}
	if (err == thrd_success) {
		err = thrd_create(&frame_thread, threaded_frame, (void *)NULL);
	}
	return err;
}

int a8bridge_init(int argc, char **argv) {
	int err;

	if (threading_status == thrd_error) {
		threading_status = init_thread();
		if (threading_status == thrd_success) {
#ifdef DEBUG_THREAD_STATUS
			printf("a8bridge_init: successfully created threading context\n");
#endif
		}
		else {
			printf("a8bridge_init: failed creating threading context: %d\n", threading_status);
		}
	}
	else {
#ifdef DEBUG_THREAD_STATUS
		printf("a8bridge_init: already created threading context: %d\n", threading_status);
#endif
	}

	err = threading_status;
	if (err == thrd_success) {
		if (!Atari800_Initialise(&argc, argv))
			err = 3;
	}
	else {
		err = 0;
	}
	return err;
}

void a8bridge_clear_state_arrays(input_template_t *input, output_template_t *output)
{
	/* Initialize input and output arrays to zero */
	memset(input, 0, sizeof(input_template_t));
	memset(output, 0, sizeof(output_template_t));
	output->status.frame_status = 0;
	output->status.cycles_since_power_on = 0;
	output->status.instructions_since_power_on = 0;
}

void a8bridge_configure_state_arrays(input_template_t *input, output_template_t *output)
{
	/* Initialize input array and calculate size of output array based on the
	machine type*/
	LIBATARI800_Input_array = input;
	LIBATARI800_Status = &output->status;
	memory_access = output->status.memory_access;
	access_type = output->status.access_type;

	INPUT_key_code = AKEY_NONE;
	LIBATARI800_Mouse();
	LIBATARI800_Frame();
	LIBATARI800_StateSave(output->state, &output->tags);
	Atari800_Coldstart();  /* reset so a8bridge_next_frame will start correctly */
}


/***** Interface for libdebugger *****/ 

int a8bridge_register_callback(uint16_t token, uint16_t addr) {
	int value;

	switch (token) {
		case REG_A:
		value = CPU_regA;
		break;

		case REG_X:
		value = CPU_regX;
		break;

		case REG_Y:
		value = CPU_regY;
		break;

		case REG_PC:
		value = CPU_regPC;
		break;

		default:
		value = 0;
	}
#ifdef DEBUG_REGISTER_CALLBACK
	printf("a8bridge_register_callback: token=%d addr=%04x value=%04x\n", token, addr, value);
#endif
	return value;
}


/***** atari800 replacement functions to hook into libdebugger *****/

int LIBATARI800_CheckBreakpoints() {
	int bpid;
	int cycles = 0; /*fixme*/

	bpid = libdebugger_check_breakpoints(LIBATARI800_Breakpoints, cycles, &a8bridge_register_callback);
	if (bpid >= 0) {
		LIBATARI800_Status->frame_status = FRAME_BREAKPOINT;
		LIBATARI800_Status->breakpoint_id = bpid;
		return bpid;
	}
	return -1;
}


int PLATFORM_Exit(int run_monitor)
{
	int err;

	Log_flushlog();

	LIBATARI800_Status->breakpoint_id = 0;

	err = cnd_broadcast(&talking_stick);
	if (err == thrd_error) {
		printf("cnd_broadcast failed in PLATFORM_Exit\n");
	}
	else {
#ifdef DEBUG_THREAD_STATUS
		printf("PLATFORM_Exit giving up the talking stick\n");
#endif
	}

	printf("Waiting for main thread to handle breakpoint...\n");

	err = cnd_wait(&talking_stick, &calculating_frame);
	if (err == thrd_error) {
		printf("cnd_wait failed in PLATFORM_Exit\n");
	}
	else {
#ifdef DEBUG_THREAD_STATUS
		printf("PLATFORM_Exit has the talking stick\n");
#endif
	}
	return 1;  /* always continue. Leave it to the client to exit */
}


/***** threading wrapper *****/

/*
 This group of code is to make a8bridge_next_frame pose as normal function from
 the user standpoint. The atari800 core has two places where it return control
 back to user code: once after Atari800_Frame returns (signifying that a
 complete frame has been drawn and is ready for display), and the other in
 PLATFORM_Exit as the link to the debugger. The problem is that PLATFORM_Exit
 can be called while still inside the the call to Atari800_Frame. This can't be
 handled with non-threaded code because the user code is still waiting for the
 return from Atari800_Frame.

 This threading code below uses a8bridge_next_frame to present a single return
 to user code. A flag is set, indicating whether the return from
 a8bridge_next_frame was caused by a complete frame or because of a debugger
 breakpoint. If it was a breakpoint, the user code can handle the debugging
 functions and call a8bridge_next_frame again and the atari800 core will pick
 up where it left off.
*/

int threaded_frame(void *arg) {
	int err = thrd_success;

	while (err == thrd_success) {
		err = cnd_wait(&talking_stick, &calculating_frame);
		if (err == thrd_error) {
			printf("cnd_wait failed in threaded_frame\n");
		}
		else {
#ifdef DEBUG_THREAD_STATUS
			printf("threaded_frame has the talking stick\n");
#endif
		}

		LIBATARI800_Mouse();

	#ifdef PBI_BB
		PBI_BB_Frame(); /* just to make the menu key go up automatically */
	#endif
	#if defined(PBI_XLD) || defined (VOICEBOX)
		VOTRAXSND_Frame(); /* for the Votrax */
	#endif
		Devices_Frame();
		INPUT_Frame();
		GTIA_Frame();
		ANTIC_Frame(TRUE);
		INPUT_DrawMousePointer();
		Screen_DrawAtariSpeed(Util_time());
		Screen_DrawDiskLED();
		Screen_Draw1200LED();
		POKEY_Frame();
	#ifdef SOUND
		Sound_Update();
	#endif
		Atari800_nframes++;

		err = cnd_broadcast(&talking_stick);
		if (err == thrd_error) {
			printf("cnd_broadcast failed in threaded_frame\n");
		}
		else {
#ifdef DEBUG_THREAD_STATUS
			printf("threaded_frame giving up the talking stick\n");
#endif
		}
	}
	printf("threaded_frame exited with %d\n", err);
	return err;
}


int a8bridge_calc_frame(frame_status_t *status, breakpoints_t *breakpoints, emulator_history_t *history) {
	int err;

	LIBATARI800_Breakpoints = breakpoints;
	LIBATARI800_Status = status;
	LIBATARI800_History = history;
	memory_access = status->memory_access;
	access_type = status->access_type;

	err = cnd_broadcast(&talking_stick);
	if (err == thrd_error) {
		printf("cnd_broadcast failed in a8bridge_calc_frame\n");
	}
	else {
#ifdef DEBUG_THREAD_STATUS
		printf("a8bridge_calc_frame giving up the talking stick\n");
#endif
	}

#ifdef DEBUG_THREAD_STATUS
	printf("a8bridge_calc_frame waiting for frame or breakpoint\n");
#endif

	err = cnd_wait(&talking_stick, &calculating_frame);
	if (err == thrd_error) {
		printf("cnd_wait failed in a8bridge_calc_frame\n");
	}
	else {
#ifdef DEBUG_THREAD_STATUS
		printf("a8bridge_calc_frame has the talking stick\n");
#endif
	}
	return LIBATARI800_Status->breakpoint_id;
}


/* Utility functions */

static void copy_screen(unsigned char *dest)
{
	unsigned char *src;
	int x, y, x_offset, xi;

	/* set up screen copy of middle 336 pixels to output buffer */
	x = Screen_visible_x2 - Screen_visible_x1;
	x_offset = (Screen_WIDTH - x) / 2;
	y = Screen_visible_y2 - Screen_visible_y1;

	src = (unsigned char *)Screen_atari;

	src = src + x_offset;
	x_offset *= 2;
	while (y > 0) {
		xi = x;
		while (xi > 0) {
			*dest++ = *src++;
			xi--;
		}
		src += x_offset;
		y--;
	}
}



/* User-visible functions */

int a8bridge_next_frame(input_template_t *input, output_template_t *output, breakpoints_t *breakpoints, emulator_history_t *history)
{
	int bpid;

	LIBATARI800_Input_array = input;
	INPUT_key_code = PLATFORM_Keyboard();

	bpid = libdebugger_calc_frame(&a8bridge_calc_frame, MEMORY_mem, &output->status, breakpoints, history);

	LIBATARI800_StateSave(output->state, &output->tags);
	if (output->status.frame_status == FRAME_FINISHED) {
		copy_screen(output->video);
	}
	return bpid;
}

void a8bridge_get_current_state(output_template_t *output)
{
	LIBATARI800_StateSave(output->state, &output->tags);
}

void a8bridge_restore_state(output_template_t *output)
{
	LIBATARI800_StateLoad(output->state);
}

/*
vim:ts=4:sw=4:
*/

