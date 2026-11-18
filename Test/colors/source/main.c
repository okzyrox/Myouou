#include <stdio.h>
#include <switch.h>

int main(int argc, char* argv[])
{
    consoleInit(NULL);
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    PadState pad;
    padInitializeDefault(&pad);

    printf("\x1b[31mRed \x1b[32mGreen \x1b[33mYellow \x1b[34mBlue \x1b[35mPurple \x1b[36mCyan \x1b[37mWhite\x1b[0m\n");
    printf("\x1b[1;31mBright Red \x1b[1;32mBright Green \x1b[1;34mBright Blue\x1b[0m\n");
    printf("\x1b[41mRed bg\x1b[0m \x1b[42;30mGreen bg\x1b[0m\n");
    printf("Plain text\n");

    while (appletMainLoop())
    {
        padUpdate(&pad);
        if (padGetButtonsDown(&pad) & HidNpadButton_Plus)
            break;
        consoleUpdate(NULL);
    }

    consoleExit(NULL);
    return 0;
}
