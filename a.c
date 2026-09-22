/******************************************************************************
 * File:        car_wiper_controller.c
 * Description: Real-Time Car Wiper Controller Application
 *              Supports multiple wiper modes, rain sensing, auto speed,
 *              wash cycles, diagnostics, and fault management.
 * Target:      ARM Cortex-M based MCU (STM32 or similar)
 * Author:      Embedded Systems Engineer
 * Version:     2.0.0
 ******************************************************************************/

/*=============================================================================
 * SECTION 1: INCLUDES AND STANDARD TYPES
 *===========================================================================*/

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/*=============================================================================
 * SECTION 2: HARDWARE ABSTRACTION LAYER (HAL) REGISTER DEFINITIONS
 *===========================================================================*/

/* Base addresses - to be configured per target MCU */
typedef volatile uint32_t reg32_t;

typedef struct {
    reg32_t MODER;
    reg32_t OTYPER;
    reg32_t OSPEEDR;
    reg32_t PUPDR;
    reg32_t IDR;
    reg32_t ODR;
    reg32_t BSRR;
    reg32_t LCKR;
    reg32_t AFRL;
    reg32_t AFRH;
} GPIO_TypeDef;

typedef struct {
    reg32_t CR1;
    reg32_t CR2;
    reg32_t SMCR;
    reg32_t DIER;
    reg32_t SR;
    reg32_t EGR;
    reg32_t CCMR1;
    reg32_t CCMR2;
    reg32_t CCER;
    reg32_t CNT;
    reg32_t PSC;
    reg32_t ARR;
    reg32_t RESERVED1;
    reg32_t CCR1;
    reg32_t CCR2;
    reg32_t CCR3;
    reg32_t CCR4;
    reg32_t RESERVED2;
    reg32_t DCR;
    reg32_t DMAR;
} TIM_TypeDef;

typedef struct {
    reg32_t SR;
    reg32_t CR1;
    reg32_t CR2;
    reg32_t SMPR1;
    reg32_t SMPR2;
    reg32_t JOFR1;
    reg32_t JOFR2;
    reg32_t JOFR3;
    reg32_t JOFR4;
    reg32_t HTR;
    reg32_t LTR;
    reg32_t SQR1;
    reg32_t SQR2;
    reg32_t SQR3;
    reg32_t JSQR;
    reg32_t JDR1;
    reg32_t JDR2;
    reg32_t JDR3;
    reg32_t JDR4;
    reg32_t DR;
} ADC_TypeDef;

typedef struct {
    reg32_t CTRL;
    reg32_t LOAD;
    reg32_t VAL;
    reg32_t CALIB;
} SYSTICK_TypeDef;

/*=============================================================================
 * SECTION 3: CONFIGURATION TABLE STRUCTURES
 *===========================================================================*/

typedef enum {
    WIPER_POSITION_PARK = 0,
    WIPER_POSITION_MIN,
    WIPER_POSITION_MAX,
    WIPER_POSITION_COUNT
} WiperPosition_t;

typedef enum {
    WIPER_MODE_OFF = 0,
    WIPER_MODE_INTERMITTENT,
    WIPER_MODE_LOW,
    WIPER_MODE_HIGH,
    WIPER_MODE_AUTO,
    WIPER_MODE_WASH,
    WIPER_MODE_SERVICE,
    WIPER_MODE_COUNT
} WiperMode_t;

typedef enum {
    WIPER_STATE_IDLE = 0,
    WIPER_STATE_PARKING,
    WIPER_STATE_SWEEP_FORWARD,
    WIPER_STATE_SWEEP_REVERSE,
    WIPER_STATE_INTERMITTENT_PAUSE,
    WIPER_STATE_WASH_SPRAY,
    WIPER_STATE_WASH_WIPE,
    WIPER_STATE_WASH_FINAL,
    WIPER_STATE_FAULT,
    WIPER_STATE_SERVICE_POSITION,
    WIPER_STATE_COUNT
} WiperState_t;

typedef enum {
    RAIN_INTENSITY_NONE = 0,
    RAIN_INTENSITY_LIGHT,
    RAIN_INTENSITY_MODERATE,
    RAIN_INTENSITY_HEAVY,
    RAIN_INTENSITY_EXTREME,
    RAIN_INTENSITY_COUNT
} RainIntensity_t;

typedef enum {
    MOTOR_DIR_STOP = 0,
    MOTOR_DIR_FORWARD,
    MOTOR_DIR_REVERSE,
    MOTOR_DIR_BRAKE
} MotorDirection_t;

typedef enum {
    FAULT_NONE              = 0x0000,
    FAULT_MOTOR_OVERCURRENT = 0x0001,
    FAULT_MOTOR_STALL       = 0x0002,
    FAULT_POSITION_SENSOR   = 0x0004,
    FAULT_RAIN_SENSOR       = 0x0008,
    FAULT_MOTOR_OVERTEMP    = 0x0010,
    FAULT_SUPPLY_VOLTAGE    = 0x0020,
    FAULT_PARK_SWITCH       = 0x0040,
    FAULT_COMM_ERROR        = 0x0080,
    FAULT_WASHER_PUMP       = 0x0100,
    FAULT_WASHER_LEVEL      = 0x0200
} FaultCode_t;

typedef enum {
    SPEED_PROFILE_LINEAR = 0,
    SPEED_PROFILE_RAMP,
    SPEED_PROFILE_SCURVE,
    SPEED_PROFILE_COUNT
} SpeedProfile_t;

typedef enum {
    VEHICLE_SPEED_PARKED = 0,
    VEHICLE_SPEED_CITY,
    VEHICLE_SPEED_HIGHWAY,
    VEHICLE_SPEED_RANGE_COUNT
} VehicleSpeedRange_t;

typedef enum {
    WIPER_FRONT = 0,
    WIPER_REAR,
    WIPER_CHANNEL_COUNT
} WiperChannel_t;

typedef enum {
    DIAG_CMD_NONE = 0,
    DIAG_CMD_READ_FAULTS,
    DIAG_CMD_CLEAR_FAULTS,
    DIAG_CMD_READ_STATUS,
    DIAG_CMD_READ_SENSORS,
    DIAG_CMD_ACTUATOR_TEST,
    DIAG_CMD_READ_CONFIG,
    DIAG_CMD_WRITE_CONFIG,
    DIAG_CMD_RESET,
    DIAG_CMD_COUNT
} DiagCommand_t;

/*=============================================================================
 * SECTION 4: CONFIGURATION STRUCTURES
 *===========================================================================*/

typedef struct {
    uint16_t adc_threshold;
    uint16_t hysteresis;
} RainThresholdConfig_t;

typedef struct {
    uint32_t interval_ms;
    uint16_t motor_pwm_duty;
} IntermittentConfig_t;

typedef struct {
    uint16_t motor_pwm_duty;
    uint16_t ramp_up_time_ms;
    uint16_t ramp_down_time_ms;
} SpeedConfig_t;

typedef struct {
    uint16_t spray_duration_ms;
    uint16_t wipe_count;
    uint16_t final_delay_ms;
    uint16_t pump_pwm_duty;
} WashConfig_t;

typedef struct {
    uint16_t overcurrent_threshold_ma;
    uint16_t stall_timeout_ms;
    uint16_t overtemp_threshold_c;
    uint16_t min_supply_voltage_mv;
    uint16_t max_supply_voltage_mv;
    uint16_t position_timeout_ms;
    uint16_t fault_debounce_count;
    uint16_t max_retry_count;
    uint32_t recovery_delay_ms;
} FaultConfig_t;

typedef struct {
    uint16_t park_position_adc;
    uint16_t max_position_adc;
    uint16_t position_tolerance;
    uint16_t park_switch_debounce_ms;
} PositionConfig_t;

typedef struct {
    RainThresholdConfig_t rain_thresholds[RAIN_INTENSITY_COUNT];
    IntermittentConfig_t  intermittent_settings[RAIN_INTENSITY_COUNT];
    SpeedConfig_t         speed_low;
    SpeedConfig_t         speed_high;
    WashConfig_t          wash_config;
    FaultConfig_t         fault_config;
    PositionConfig_t      position_config;
    uint16_t              rain_sensor_sample_period_ms;
    uint16_t              rain_sensor_filter_coeff;
    uint16_t              auto_sensitivity;
    SpeedProfile_t        speed_profile;
    uint32_t              main_task_period_ms;
    uint32_t              sensor_task_period_ms;
    uint32_t              diagnostic_task_period_ms;
} WiperConfig_t;

/*=============================================================================
 * SECTION 5: RUNTIME DATA STRUCTURES
 *===========================================================================*/

typedef struct {
    uint16_t raw_value;
    uint16_t filtered_value;
    uint16_t min_value;
    uint16_t max_value;
    bool     valid;
    uint32_t last_sample_time;
    uint32_t sample_count;
    int32_t  filter_accumulator;
} SensorData_t;

typedef struct {
    MotorDirection_t direction;
    uint16_t         current_pwm;
    uint16_t         target_pwm;
    uint16_t         ramp_step;
    bool             is_running;
    uint32_t         runtime_ms;
    uint32_t         start_time;
    uint32_t         total_cycles;
} MotorControl_t;

typedef struct {
    uint16_t     active_faults;
    uint16_t     historical_faults;
    uint16_t     fault_counters[16];
    uint32_t     fault_timestamps[16];
    uint8_t      retry_counters[16];
    bool         fault_recovery_active;
    uint32_t     recovery_start_time;
} FaultManager_t;

typedef struct {
    WiperMode_t      current_mode;
    WiperMode_t      requested_mode;
    WiperState_t     current_state;
    WiperState_t     previous_state;
    uint32_t         state_entry_time;
    uint32_t         state_elapsed_time;
    uint16_t         current_position;
    bool             park_switch_active;
    bool             park_switch_debounced;
    uint32_t         park_debounce_time;
    uint8_t          wash_wipe_counter;
    uint8_t          intermittent_level;
    RainIntensity_t  rain_intensity;
    RainIntensity_t  prev_rain_intensity;
    uint32_t         rain_change_time;
    bool             ignition_active;
    bool             service_mode;
    uint16_t         vehicle_speed_kmh;
    VehicleSpeedRange_t vehicle_speed_range;
} WiperRuntime_t;

typedef struct {
    uint32_t total_wipe_cycles;
    uint32_t total_wash_cycles;
    uint32_t total_runtime_sec;
    uint32_t motor_on_time_sec;
    uint32_t last_service_time;
    uint32_t fault_event_count;
    uint16_t max_motor_current_ma;
    uint16_t max_temperature_c;
} WiperStatistics_t;

typedef struct {
    DiagCommand_t pending_command;
    uint8_t       command_data[64];
    uint8_t       response_data[128];
    uint16_t      response_length;
    bool          command_complete;
    bool          test_active;
    uint8_t       test_channel;
    uint32_t      test_start_time;
    uint32_t      test_duration_ms;
} DiagnosticManager_t;

typedef struct {
    uint32_t values[32];
    uint8_t  index;
    uint8_t  count;
    uint8_t  size;
    uint32_t sum;
} MovingAverageFilter_t;

typedef struct {
    bool     pressed;
    bool     released;
    bool     held;
    bool     raw_state;
    bool     debounced_state;
    bool     prev_debounced_state;
    uint32_t press_time;
    uint32_t release_time;
    uint32_t hold_duration;
    uint8_t  debounce_counter;
    uint8_t  debounce_threshold;
} ButtonState_t;

typedef struct {
    ButtonState_t mode_switch;
    ButtonState_t intermittent_up;
    ButtonState_t intermittent_down;
    ButtonState_t wash_button;
    ButtonState_t service_button;
} InputManager_t;

/*=============================================================================
 * SECTION 6: GLOBAL SYSTEM CONTEXT
 *===========================================================================*/

typedef struct {
    WiperConfig_t        config;
    WiperRuntime_t       runtime[WIPER_CHANNEL_COUNT];
    MotorControl_t       motor[WIPER_CHANNEL_COUNT];
    SensorData_t         rain_sensor;
    SensorData_t         position_sensor[WIPER_CHANNEL_COUNT];
    SensorData_t         current_sensor[WIPER_CHANNEL_COUNT];
    SensorData_t         temperature_sensor;
    SensorData_t         voltage_sensor;
    FaultManager_t       fault_mgr;
    WiperStatistics_t    statistics;
    DiagnosticManager_t  diagnostics;
    InputManager_t       inputs;
    MovingAverageFilter_t rain_filter;
    MovingAverageFilter_t current_filter[WIPER_CHANNEL_COUNT];
    uint32_t             system_tick_ms;
    uint32_t             last_main_task_time;
    uint32_t             last_sensor_task_time;
    uint32_t             last_diag_task_time;
    uint32_t             last_stats_update_time;
    bool                 system_initialized;
    uint8_t              system_error_code;
} WiperSystem_t;

static WiperSystem_t g_wiper_system;

/*=============================================================================
 * SECTION 7: FUNCTION PROTOTYPES
 *===========================================================================*/

/* System initialization */
static void System_Init(WiperSystem_t *sys);
static void Config_LoadDefaults(WiperConfig_t *cfg);
static void Runtime_Init(WiperRuntime_t *rt);
static void Motor_Init(MotorControl_t *motor);
static void Sensor_Init(SensorData_t *sensor);
static void FaultManager_Init(FaultManager_t *fm);
static void Statistics_Init(WiperStatistics_t *stats);
static void Diagnostics_Init(DiagnosticManager_t *diag);
static void Filter_Init(MovingAverageFilter_t *filter, uint8_t size);
static void Input_Init(InputManager_t *inputs);
static void Button_Init(ButtonState_t *btn, uint8_t debounce_threshold);

/* HAL functions */
static void HAL_GPIO_Init(void);
static void HAL_Timer_Init(void);
static void HAL_ADC_Init(void);
static void HAL_PWM_Init(void);
static void HAL_GPIO_WritePin(uint8_t port, uint8_t pin, bool state);
static bool HAL_GPIO_ReadPin(uint8_t port, uint8_t pin);
static uint16_t HAL_ADC_Read(uint8_t channel);
static void HAL_PWM_SetDuty(uint8_t channel, uint16_t duty);
static void HAL_PWM_Start(uint8_t channel);
static void HAL_PWM_Stop(uint8_t channel);
static uint32_t HAL_GetTick(void);
static void HAL_DelayMs(uint32_t ms);
static void HAL_WatchdogReset(void);
static void HAL_EnterCritical(void);
static void HAL_ExitCritical(void);

/* Sensor processing */
static void Sensor_ReadAll(WiperSystem_t *sys);
static void Sensor_ReadRain(WiperSystem_t *sys);
static void Sensor_ReadPosition(WiperSystem_t *sys, WiperChannel_t ch);
static void Sensor_ReadCurrent(WiperSystem_t *sys, WiperChannel_t ch);
static void Sensor_ReadTemperature(WiperSystem_t *sys);
static void Sensor_ReadVoltage(WiperSystem_t *sys);
static uint16_t Sensor_ApplyFilter(SensorData_t *sensor, uint16_t raw, uint16_t coeff);
static uint32_t Filter_Update(MovingAverageFilter_t *filter, uint32_t value);

/* Rain intensity detection */
static RainIntensity_t Rain_ClassifyIntensity(WiperSystem_t *sys);
static WiperMode_t Rain_DetermineAutoMode(WiperSystem_t *sys, RainIntensity_t intensity);
static uint32_t Rain_GetIntermittentInterval(WiperSystem_t *sys, RainIntensity_t intensity);

/* Input processing */
static void Input_ProcessAll(WiperSystem_t *sys);
static void Button_Process(ButtonState_t *btn, bool raw_input, uint32_t current_time);
static WiperMode_t Input_DetermineRequestedMode(WiperSystem_t *sys);
static uint8_t Input_GetIntermittentLevel(WiperSystem_t *sys);
static VehicleSpeedRange_t Input_ClassifyVehicleSpeed(uint16_t speed_kmh);

/* State machine */
static void StateMachine_Process(WiperSystem_t *sys, WiperChannel_t ch);
static void StateMachine_TransitionTo(WiperSystem_t *sys, WiperChannel_t ch, WiperState_t new_state);
static void State_Idle_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_Idle_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_Parking_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_Parking_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_SweepForward_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_SweepForward_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_SweepReverse_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_SweepReverse_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_IntermittentPause_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_IntermittentPause_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_WashSpray_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_WashSpray_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_WashWipe_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_WashWipe_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_WashFinal_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_WashFinal_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_Fault_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_Fault_Execute(WiperSystem_t *sys, WiperChannel_t ch);
static void State_ServicePosition_Entry(WiperSystem_t *sys, WiperChannel_t ch);
static void State_ServicePosition_Execute(WiperSystem_t *sys, WiperChannel_t ch);

/* Motor control */
static void Motor_SetDirection(WiperSystem_t *sys, WiperChannel_t ch, MotorDirection_t dir);
static void Motor_SetSpeed(WiperSystem_t *sys, WiperChannel_t ch, uint16_t pwm_duty);
static void Motor_Stop(WiperSystem_t *sys, WiperChannel_t ch);
static void Motor_Brake(WiperSystem_t *sys, WiperChannel_t ch);
static void Motor_UpdateRamp(WiperSystem_t *sys, WiperChannel_t ch);
static uint16_t Motor_CalculateRampStep(uint16_t target, uint16_t current, uint16_t ramp_time_ms, uint32_t period_ms);
static bool Motor_IsAtPosition(WiperSystem_t *sys, WiperChannel_t ch, WiperPosition_t pos);
static uint16_t Motor_GetSpeedForMode(WiperSystem_t *sys, WiperMode_t mode);

/* Washer control */
static void Washer_PumpOn(WiperSystem_t *sys, uint16_t pwm_duty);
static void Washer_PumpOff(WiperSystem_t *sys);
static bool Washer_IsFluidAvailable(WiperSystem_t *sys);

/* Fault management */
static void Fault_ProcessAll(WiperSystem_t *sys);
static void Fault_CheckMotorCurrent(WiperSystem_t *sys, WiperChannel_t ch);
static void Fault_CheckMotorStall(WiperSystem_t *sys, WiperChannel_t ch);
static void Fault_CheckPositionSensor(WiperSystem_t *sys, WiperChannel_t ch);
static void Fault_CheckRainSensor(WiperSystem_t *sys);
static void Fault_CheckTemperature(WiperSystem_t *sys);
static void Fault_CheckSupplyVoltage(WiperSystem_t *sys);
static void Fault_SetFault(WiperSystem_t *sys, FaultCode_t fault);
static void Fault_ClearFault(WiperSystem_t *sys, FaultCode_t fault);
static bool Fault_IsActive(WiperSystem_t *sys, FaultCode_t fault);
static bool Fault_IsCritical(WiperSystem_t *sys);
static void Fault_AttemptRecovery(WiperSystem_t *sys);

/* Diagnostics */
static void Diagnostics_Process(WiperSystem_t *sys);
static void Diagnostics_HandleCommand(WiperSystem_t *sys);
static void Diagnostics_ReadFaults(WiperSystem_t *sys);
static void Diagnostics_ClearFaults(WiperSystem_t *sys);
static void Diagnostics_ReadStatus(WiperSystem_t *sys);
static void Diagnostics_ReadSensors(WiperSystem_t *sys);
static void Diagnostics_ActuatorTest(WiperSystem_t *sys);
static void Diagnostics_ReadConfig(WiperSystem_t *sys);
static void Diagnostics_WriteConfig(WiperSystem_t *sys);

/* Statistics */
static void Statistics_Update(WiperSystem_t *sys);

/* Utility functions */
static uint32_t Util_ElapsedTime(uint32_t start_time, uint32_t current_time);
static uint16_t Util_Clamp16(uint16_t value, uint16_t min_val, uint16_t max_val);
static int32_t Util_Map(int32_t value, int32_t in_min, int32_t in_max, int32_t out_min, int32_t out_max);
static uint16_t Util_AbsDiff16(uint16_t a, uint16_t b);
static bool Util_InRange(uint16_t value, uint16_t center, uint16_t tolerance);

/* Main task functions */
static void Task_MainControl(WiperSystem_t *sys);
static void Task_SensorProcessing(WiperSystem_t *sys);
static void Task_Diagnostics(WiperSystem_t *sys);
static void Task_Statistics(WiperSystem_t *sys);

/*=============================================================================
 * SECTION 8: CONFIGURATION DEFAULTS LOADER
 *===========================================================================*/

static void Config_LoadDefaults(WiperConfig_t *cfg)
{
    uint8_t i;

    if (cfg == NULL) {
        return;
    }

    memset(cfg, 0, sizeof(WiperConfig_t));

    /* Rain sensor thresholds (ADC values 0-4095) */
    cfg->rain_thresholds[RAIN_INTENSITY_NONE].adc_threshold     = 200;
    cfg->rain_thresholds[RAIN_INTENSITY_NONE].hysteresis        = 30;
    cfg->rain_thresholds[RAIN_INTENSITY_LIGHT].adc_threshold    = 800;
    cfg->rain_thresholds[RAIN_INTENSITY_LIGHT].hysteresis       = 50;
    cfg->rain_thresholds[RAIN_INTENSITY_MODERATE].adc_threshold = 1800;
    cfg->rain_thresholds[RAIN_INTENSITY_MODERATE].hysteresis    = 80;
    cfg->rain_thresholds[RAIN_INTENSITY_HEAVY].adc_threshold    = 2800;
    cfg->rain_thresholds[RAIN_INTENSITY_HEAVY].hysteresis       = 100;
    cfg->rain_thresholds[RAIN_INTENSITY_EXTREME].adc_threshold  = 3600;
    cfg->rain_thresholds[RAIN_INTENSITY_EXTREME].hysteresis     = 100;

    /* Intermittent intervals per rain intensity */
    cfg->intermittent_settings[RAIN_INTENSITY_NONE].interval_ms     = 8000;
    cfg->intermittent_settings[RAIN_INTENSITY_NONE].motor_pwm_duty  = 500;
    cfg->intermittent_settings[RAIN_INTENSITY_LIGHT].interval_ms    = 5000;
    cfg->intermittent_settings[RAIN_INTENSITY_LIGHT].motor_pwm_duty = 550;
    cfg->intermittent_settings[RAIN_INTENSITY_MODERATE].interval_ms    = 3000;
    cfg->intermittent_settings[RAIN_INTENSITY_MODERATE].motor_pwm_duty = 600;
    cfg->intermittent_settings[RAIN_INTENSITY_HEAVY].interval_ms    = 1500;
    cfg->intermittent_settings[RAIN_INTENSITY_HEAVY].motor_pwm_duty = 700;
    cfg->intermittent_settings[RAIN_INTENSITY_EXTREME].interval_ms    = 800;
    cfg->intermittent_settings[RAIN_INTENSITY_EXTREME].motor_pwm_duty = 800;

    /* Speed configurations */
    cfg->speed_low.motor_pwm_duty   = 600;
    cfg->speed_low.ramp_up_time_ms  = 300;
    cfg->speed_low.ramp_down_time_ms = 200;

    cfg->speed_high.motor_pwm_duty   = 900;
    cfg->speed_high.ramp_up_time_ms  = 200;
    cfg->speed_high.ramp_down_time_ms = 150;

    /* Wash configuration */
    cfg->wash_config.spray_duration_ms = 2000;
    cfg->wash_config.wipe_count        = 3;
    cfg->wash_config.final_delay_ms    = 4000;
    cfg->wash_config.pump_pwm_duty     = 800;

    /* Fault configuration */
    cfg->fault_config.overcurrent_threshold_ma = 5000;
    cfg->fault_config.stall_timeout_ms         = 3000;
    cfg->fault_config.overtemp_threshold_c     = 85;
    cfg->fault_config.min_supply_voltage_mv    = 9000;
    cfg->fault_config.max_supply_voltage_mv    = 16000;
    cfg->fault_config.position_timeout_ms      = 5000;
    cfg->fault_config.fault_debounce_count     = 3;
    cfg->fault_config.max_retry_count          = 3;
    cfg->fault_config.recovery_delay_ms        = 5000;

    /* Position configuration */
    cfg->position_config.park_position_adc     = 200;
    cfg->position_config.max_position_adc      = 3800;
    cfg->position_config.position_tolerance    = 100;
    cfg->position_config.park_switch_debounce_ms = 50;

    /* General configuration */
    cfg->rain_sensor_sample_period_ms = 50;
    cfg->rain_sensor_filter_coeff     = 8;
    cfg->auto_sensitivity             = 50;
    cfg->speed_profile                = SPEED_PROFILE_RAMP;
    cfg->main_task_period_ms          = 10;
    cfg->sensor_task_period_ms        = 20;
    cfg->diagnostic_task_period_ms    = 100;
}

/*=============================================================================
 * SECTION 9: INITIALIZATION FUNCTIONS
 *===========================================================================*/

static void System_Init(WiperSystem_t *sys)
{
    uint8_t ch;

    if (sys == NULL) {
        return;
    }

    memset(sys, 0, sizeof(WiperSystem_t));

    Config_LoadDefaults(&sys->config);

    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        Runtime_Init(&sys->runtime[ch]);
        Motor_Init(&sys->motor[ch]);
        Sensor_Init(&sys->position_sensor[ch]);
        Sensor_Init(&sys->current_sensor[ch]);
        Filter_Init(&sys->current_filter[ch], 16);
    }

    Sensor_Init(&sys->rain_sensor);
    Sensor_Init(&sys->temperature_sensor);
    Sensor_Init(&sys->voltage_sensor);
    FaultManager_Init(&sys->fault_mgr);
    Statistics_Init(&sys->statistics);
    Diagnostics_Init(&sys->diagnostics);
    Filter_Init(&sys->rain_filter, 16);
    Input_Init(&sys->inputs);

    HAL_GPIO_Init();
    HAL_Timer_Init();
    HAL_ADC_Init();
    HAL_PWM_Init();

    sys->system_tick_ms = HAL_GetTick();
    sys->last_main_task_time   = sys->system_tick_ms;
    sys->last_sensor_task_time = sys->system_tick_ms;
    sys->last_diag_task_time   = sys->system_tick_ms;
    sys->last_stats_update_time = sys->system_tick_ms;

    sys->system_initialized = true;
    sys->system_error_code  = 0;
}

static void Runtime_Init(WiperRuntime_t *rt)
{
    if (rt == NULL) {
        return;
    }

    memset(rt, 0, sizeof(WiperRuntime_t));
    rt->current_mode     = WIPER_MODE_OFF;
    rt->requested_mode   = WIPER_MODE_OFF;
    rt->current_state    = WIPER_STATE_IDLE;
    rt->previous_state   = WIPER_STATE_IDLE;
    rt->rain_intensity   = RAIN_INTENSITY_NONE;
    rt->prev_rain_intensity = RAIN_INTENSITY_NONE;
    rt->intermittent_level  = 3;
    rt->ignition_active     = false;
    rt->service_mode        = false;
    rt->vehicle_speed_kmh   = 0;
    rt->vehicle_speed_range = VEHICLE_SPEED_PARKED;
}

static void Motor_Init(MotorControl_t *motor)
{
    if (motor == NULL) {
        return;
    }

    memset(motor, 0, sizeof(MotorControl_t));
    motor->direction   = MOTOR_DIR_STOP;
    motor->current_pwm = 0;
    motor->target_pwm  = 0;
    motor->is_running  = false;
}

static void Sensor_Init(SensorData_t *sensor)
{
    if (sensor == NULL) {
        return;
    }

    memset(sensor, 0, sizeof(SensorData_t));
    sensor->min_value = UINT16_MAX;
    sensor->max_value = 0;
    sensor->valid     = false;
}

static void FaultManager_Init(FaultManager_t *fm)
{
    if (fm == NULL) {
        return;
    }

    memset(fm, 0, sizeof(FaultManager_t));
}

static void Statistics_Init(WiperStatistics_t *stats)
{
    if (stats == NULL) {
        return;
    }

    memset(stats, 0, sizeof(WiperStatistics_t));
}

static void Diagnostics_Init(DiagnosticManager_t *diag)
{
    if (diag == NULL) {
        return;
    }

    memset(diag, 0, sizeof(DiagnosticManager_t));
    diag->pending_command  = DIAG_CMD_NONE;
    diag->command_complete = true;
    diag->test_active      = false;
}

static void Filter_Init(MovingAverageFilter_t *filter, uint8_t size)
{
    if (filter == NULL) {
        return;
    }

    memset(filter, 0, sizeof(MovingAverageFilter_t));
    if (size > 32) {
        size = 32;
    }
    filter->size  = size;
    filter->index = 0;
    filter->count = 0;
    filter->sum   = 0;
}

static void Input_Init(InputManager_t *inputs)
{
    uint8_t debounce_val;

    if (inputs == NULL) {
        return;
    }

    debounce_val = 5;
    Button_Init(&inputs->mode_switch, debounce_val);
    Button_Init(&inputs->intermittent_up, debounce_val);
    Button_Init(&inputs->intermittent_down, debounce_val);
    Button_Init(&inputs->wash_button, debounce_val);
    Button_Init(&inputs->service_button, 10);
}

static void Button_Init(ButtonState_t *btn, uint8_t debounce_threshold)
{
    if (btn == NULL) {
        return;
    }

    memset(btn, 0, sizeof(ButtonState_t));
    btn->debounce_threshold = debounce_threshold;
}

/*=============================================================================
 * SECTION 10: HAL IMPLEMENTATIONS (Platform-specific stubs)
 *===========================================================================*/

/* GPIO pin definitions */
#define GPIO_PORT_MOTOR       0
#define GPIO_PIN_MOTOR_FWD_A  0
#define GPIO_PIN_MOTOR_REV_A  1
#define GPIO_PIN_MOTOR_FWD_B  2
#define GPIO_PIN_MOTOR_REV_B  3
#define GPIO_PIN_WASH_PUMP    4
#define GPIO_PIN_STATUS_LED   5

#define GPIO_PORT_INPUT       1
#define GPIO_PIN_PARK_SW_A    0
#define GPIO_PIN_PARK_SW_B    1
#define GPIO_PIN_IGNITION     2
#define GPIO_PIN_WASH_LEVEL   3
#define GPIO_PIN_MODE_SW      4
#define GPIO_PIN_INT_UP       5
#define GPIO_PIN_INT_DOWN     6
#define GPIO_PIN_WASH_BTN     7
#define GPIO_PIN_SERVICE_BTN  8

#define ADC_CH_RAIN_SENSOR    0
#define ADC_CH_POSITION_A     1
#define ADC_CH_POSITION_B     2
#define ADC_CH_CURRENT_A      3
#define ADC_CH_CURRENT_B      4
#define ADC_CH_TEMPERATURE    5
#define ADC_CH_VOLTAGE        6

#define PWM_CH_MOTOR_A        0
#define PWM_CH_MOTOR_B        1
#define PWM_CH_WASH_PUMP      2

/* Simulated tick counter for HAL */
static volatile uint32_t hal_tick_counter = 0;

static void HAL_GPIO_Init(void)
{
    /* Configure GPIO pins for motor control outputs */
    /* Configure GPIO pins for input switches */
    /* Platform-specific register configuration */
}

static void HAL_Timer_Init(void)
{
    /* Configure system tick timer for 1ms interrupts */
    /* Configure PWM timer for motor control */
    /* Platform-specific timer setup */
}

static void HAL_ADC_Init(void)
{
    /* Configure ADC for multi-channel scanning */
    /* Set up ADC sampling rates and resolution */
    /* Platform-specific ADC configuration */
}

static void HAL_PWM_Init(void)
{
    /* Configure PWM channels for motor speed control */
    /* Set PWM frequency and initial duty cycle */
    /* Platform-specific PWM setup */
}

static void HAL_GPIO_WritePin(uint8_t port, uint8_t pin, bool state)
{
    /* Write to GPIO output pin */
    (void)port;
    (void)pin;
    (void)state;
}

static bool HAL_GPIO_ReadPin(uint8_t port, uint8_t pin)
{
    /* Read from GPIO input pin */
    (void)port;
    (void)pin;
    return false;
}

static uint16_t HAL_ADC_Read(uint8_t channel)
{
    /* Read ADC conversion result for specified channel */
    (void)channel;
    return 0;
}

static void HAL_PWM_SetDuty(uint8_t channel, uint16_t duty)
{
    /* Set PWM duty cycle (0-1000 = 0-100%) */
    (void)channel;
    (void)duty;
}

static void HAL_PWM_Start(uint8_t channel)
{
    (void)channel;
}

static void HAL_PWM_Stop(uint8_t channel)
{
    (void)channel;
}

static uint32_t HAL_GetTick(void)
{
    return hal_tick_counter;
}

static void HAL_DelayMs(uint32_t ms)
{
    uint32_t start = HAL_GetTick();
    while (Util_ElapsedTime(start, HAL_GetTick()) < ms) {
        /* Busy wait - in real system would use low power wait */
    }
}

static void HAL_WatchdogReset(void)
{
    /* Reset hardware watchdog timer */
}

static void HAL_EnterCritical(void)
{
    /* Disable interrupts for critical section */
}

static void HAL_ExitCritical(void)
{
    /* Re-enable interrupts */
}

/*=============================================================================
 * SECTION 11: SYSTICK INTERRUPT HANDLER
 *===========================================================================*/

void SysTick_Handler(void)
{
    hal_tick_counter++;
}

/*=============================================================================
 * SECTION 12: UTILITY FUNCTIONS
 *===========================================================================*/

static uint32_t Util_ElapsedTime(uint32_t start_time, uint32_t current_time)
{
    if (current_time >= start_time) {
        return current_time - start_time;
    } else {
        /* Handle tick counter rollover */
        return (UINT32_MAX - start_time) + current_time + 1;
    }
}

static uint16_t Util_Clamp16(uint16_t value, uint16_t min_val, uint16_t max_val)
{
    if (value < min_val) {
        return min_val;
    }
    if (value > max_val) {
        return max_val;
    }
    return value;
}

static int32_t Util_Map(int32_t value, int32_t in_min, int32_t in_max,
                        int32_t out_min, int32_t out_max)
{
    int32_t in_range;
    int32_t out_range;

    in_range = in_max - in_min;
    if (in_range == 0) {
        return out_min;
    }

    out_range = out_max - out_min;
    return out_min + ((value - in_min) * out_range) / in_range;
}

static uint16_t Util_AbsDiff16(uint16_t a, uint16_t b)
{
    if (a >= b) {
        return a - b;
    }
    return b - a;
}

static bool Util_InRange(uint16_t value, uint16_t center, uint16_t tolerance)
{
    return (Util_AbsDiff16(value, center) <= tolerance);
}

/*=============================================================================
 * SECTION 13: FILTER FUNCTIONS
 *===========================================================================*/

static uint32_t Filter_Update(MovingAverageFilter_t *filter, uint32_t value)
{
    if (filter == NULL || filter->size == 0) {
        return value;
    }

    /* Subtract oldest value from sum if buffer is full */
    if (filter->count >= filter->size) {
        filter->sum -= filter->values[filter->index];
    } else {
        filter->count++;
    }

    /* Add new value */
    filter->values[filter->index] = value;
    filter->sum += value;

    /* Advance circular index */
    filter->index++;
    if (filter->index >= filter->size) {
        filter->index = 0;
    }

    /* Return average */
    return filter->sum / filter->count;
}

static uint16_t Sensor_ApplyFilter(SensorData_t *sensor, uint16_t raw, uint16_t coeff)
{
    int32_t filtered;

    if (sensor == NULL) {
        return raw;
    }

    if (sensor->sample_count == 0) {
        /* First sample, initialize filter */
        sensor->filter_accumulator = (int32_t)raw << 8;
    } else {
        /* Exponential moving average: y[n] = y[n-1] + (x[n] - y[n-1]) / coeff */
        if (coeff == 0) {
            coeff = 1;
        }
        filtered = sensor->filter_accumulator;
        filtered += ((int32_t)raw - (filtered >> 8)) * 256 / (int32_t)coeff;
        sensor->filter_accumulator = filtered;
    }

    sensor->sample_count++;
    return (uint16_t)(sensor->filter_accumulator >> 8);
}

/*=============================================================================
 * SECTION 14: SENSOR READING FUNCTIONS
 *===========================================================================*/

static void Sensor_ReadAll(WiperSystem_t *sys)
{
    uint8_t ch;

    if (sys == NULL) {
        return;
    }

    Sensor_ReadRain(sys);

    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        Sensor_ReadPosition(sys, (WiperChannel_t)ch);
        Sensor_ReadCurrent(sys, (WiperChannel_t)ch);
    }

    Sensor_ReadTemperature(sys);
    Sensor_ReadVoltage(sys);
}

static void Sensor_ReadRain(WiperSystem_t *sys)
{
    uint16_t raw;
    uint16_t filtered;
    SensorData_t *sensor;

    sensor = &sys->rain_sensor;
    raw = HAL_ADC_Read(ADC_CH_RAIN_SENSOR);

    sensor->raw_value = raw;
    filtered = Sensor_ApplyFilter(sensor, raw, sys->config.rain_sensor_filter_coeff);
    sensor->filtered_value = (uint16_t)Filter_Update(&sys->rain_filter, filtered);

    /* Track min/max */
    if (sensor->filtered_value < sensor->min_value) {
        sensor->min_value = sensor->filtered_value;
    }
    if (sensor->filtered_value > sensor->max_value) {
        sensor->max_value = sensor->filtered_value;
    }

    /* Validate sensor (check if within plausible range) */
    sensor->valid = (raw > 10 && raw < 4080);
    sensor->last_sample_time = sys->system_tick_ms;
}

static void Sensor_ReadPosition(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint16_t raw;
    SensorData_t *sensor;
    uint8_t adc_channel;

    sensor = &sys->position_sensor[ch];
    adc_channel = (ch == WIPER_FRONT) ? ADC_CH_POSITION_A : ADC_CH_POSITION_B;
    raw = HAL_ADC_Read(adc_channel);

    sensor->raw_value = raw;
    sensor->filtered_value = Sensor_ApplyFilter(sensor, raw, 4);

    if (sensor->filtered_value < sensor->min_value) {
        sensor->min_value = sensor->filtered_value;
    }
    if (sensor->filtered_value > sensor->max_value) {
        sensor->max_value = sensor->filtered_value;
    }

    sensor->valid = (raw > 5 && raw < 4090);
    sensor->last_sample_time = sys->system_tick_ms;

    /* Update runtime position */
    sys->runtime[ch].current_position = sensor->filtered_value;
}

static void Sensor_ReadCurrent(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint16_t raw;
    SensorData_t *sensor;
    uint8_t adc_channel;

    sensor = &sys->current_sensor[ch];
    adc_channel = (ch == WIPER_FRONT) ? ADC_CH_CURRENT_A : ADC_CH_CURRENT_B;
    raw = HAL_ADC_Read(adc_channel);

    sensor->raw_value = raw;
    sensor->filtered_value = (uint16_t)Filter_Update(&sys->current_filter[ch], raw);

    if (sensor->filtered_value < sensor->min_value) {
        sensor->min_value = sensor->filtered_value;
    }
    if (sensor->filtered_value > sensor->max_value) {
        sensor->max_value = sensor->filtered_value;
    }

    sensor->valid = true;
    sensor->last_sample_time = sys->system_tick_ms;
}

static void Sensor_ReadTemperature(WiperSystem_t *sys)
{
    uint16_t raw;
    SensorData_t *sensor;

    sensor = &sys->temperature_sensor;
    raw = HAL_ADC_Read(ADC_CH_TEMPERATURE);

    sensor->raw_value = raw;
    sensor->filtered_value = Sensor_ApplyFilter(sensor, raw, 16);

    if (sensor->filtered_value < sensor->min_value) {
        sensor->min_value = sensor->filtered_value;
    }
    if (sensor->filtered_value > sensor->max_value) {
        sensor->max_value = sensor->filtered_value;
    }

    sensor->valid = (raw > 100 && raw < 3900);
    sensor->last_sample_time = sys->system_tick_ms;
}

static void Sensor_ReadVoltage(WiperSystem_t *sys)
{
    uint16_t raw;
    SensorData_t *sensor;

    sensor = &sys->voltage_sensor;
    raw = HAL_ADC_Read(ADC_CH_VOLTAGE);

    sensor->raw_value = raw;
    sensor->filtered_value = Sensor_ApplyFilter(sensor, raw, 8);

    if (sensor->filtered_value < sensor->min_value) {
        sensor->min_value = sensor->filtered_value;
    }
    if (sensor->filtered_value > sensor->max_value) {
        sensor->max_value = sensor->filtered_value;
    }

    sensor->valid = (raw > 50);
    sensor->last_sample_time = sys->system_tick_ms;
}

/*=============================================================================
 * SECTION 15: RAIN INTENSITY CLASSIFICATION
 *===========================================================================*/

static RainIntensity_t Rain_ClassifyIntensity(WiperSystem_t *sys)
{
    uint16_t rain_value;
    RainIntensity_t current_intensity;
    RainIntensity_t new_intensity;
    RainThresholdConfig_t *thresholds;
    int8_t i;

    if (sys == NULL || !sys->rain_sensor.valid) {
        return RAIN_INTENSITY_NONE;
    }

    rain_value = sys->rain_sensor.filtered_value;
    current_intensity = sys->runtime[WIPER_FRONT].rain_intensity;
    thresholds = sys->config.rain_thresholds;
    new_intensity = RAIN_INTENSITY_NONE;

    /* Apply sensitivity adjustment */
    /* Check from highest to lowest intensity */
    for (i = (int8_t)(RAIN_INTENSITY_EXTREME); i >= (int8_t)(RAIN_INTENSITY_LIGHT); i--) {
        uint16_t threshold = thresholds[i].adc_threshold;
        uint16_t hysteresis = thresholds[i].hysteresis;

        /* Apply hysteresis based on current direction */
        if ((RainIntensity_t)i <= current_intensity) {
            /* Currently at or above this level, use lower threshold */
            if (rain_value >= (threshold - hysteresis)) {
                new_intensity = (RainIntensity_t)i;
                break;
            }
        } else {
            /* Currently below this level, use upper threshold */
            if (rain_value >= (threshold + hysteresis)) {
                new_intensity = (RainIntensity_t)i;
                break;
            }
        }
    }

    /* Apply sensitivity scaling */
    if (sys->config.auto_sensitivity < 50 && new_intensity > RAIN_INTENSITY_NONE) {
        /* Less sensitive - require higher intensity before triggering */
        if (new_intensity == RAIN_INTENSITY_LIGHT && sys->config.auto_sensitivity < 25) {
            new_intensity = RAIN_INTENSITY_NONE;
        }
    }

    return new_intensity;
}

static WiperMode_t Rain_DetermineAutoMode(WiperSystem_t *sys, RainIntensity_t intensity)
{
    WiperMode_t mode;

    switch (intensity) {
        case RAIN_INTENSITY_NONE:
            mode = WIPER_MODE_OFF;
            break;
        case RAIN_INTENSITY_LIGHT:
            mode = WIPER_MODE_INTERMITTENT;
            break;
        case RAIN_INTENSITY_MODERATE:
            mode = WIPER_MODE_INTERMITTENT;
            break;
        case RAIN_INTENSITY_HEAVY:
            mode = WIPER_MODE_LOW;
            break;
        case RAIN_INTENSITY_EXTREME:
            mode = WIPER_MODE_HIGH;
            break;
        default:
            mode = WIPER_MODE_OFF;
            break;
    }

    /* Adjust for vehicle speed */
    if (sys->runtime[WIPER_FRONT].vehicle_speed_range == VEHICLE_SPEED_HIGHWAY) {
        /* At highway speeds, increase wiper speed due to more water impact */
        if (mode == WIPER_MODE_INTERMITTENT) {
            mode = WIPER_MODE_LOW;
        } else if (mode == WIPER_MODE_LOW) {
            mode = WIPER_MODE_HIGH;
        }
    }

    return mode;
}

static uint32_t Rain_GetIntermittentInterval(WiperSystem_t *sys, RainIntensity_t intensity)
{
    uint32_t interval;
    uint8_t level;

    if (intensity >= RAIN_INTENSITY_COUNT) {
        intensity = RAIN_INTENSITY_NONE;
    }

    interval = sys->config.intermittent_settings[intensity].interval_ms;

    /* Adjust based on user-selected intermittent level */
    level = sys->runtime[WIPER_FRONT].intermittent_level;

    /* Level 1-6: Scale interval. Level 1 = slowest, 6 = fastest */
    if (level > 0 && level <= 6) {
        /* Scale: level 1 = 150%, level 3 = 100%, level 6 = 50% */
        int32_t scale = 150 - ((int32_t)(level - 1) * 20);
        if (scale < 30) {
            scale = 30;
        }
        interval = (interval * (uint32_t)scale) / 100;
    }

    /* Adjust for vehicle speed */
    if (sys->runtime[WIPER_FRONT].vehicle_speed_range == VEHICLE_SPEED_HIGHWAY) {
        interval = (interval * 70) / 100;  /* 30% faster at highway speeds */
    } else if (sys->runtime[WIPER_FRONT].vehicle_speed_range == VEHICLE_SPEED_CITY) {
        interval = (interval * 85) / 100;  /* 15% faster in city */
    }

    /* Ensure minimum interval */
    if (interval < 500) {
        interval = 500;
    }

    return interval;
}

/*=============================================================================
 * SECTION 16: INPUT PROCESSING
 *===========================================================================*/

static void Input_ProcessAll(WiperSystem_t *sys)
{
    bool raw_state;
    uint32_t current_time;

    if (sys == NULL) {
        return;
    }

    current_time = sys->system_tick_ms;

    /* Read ignition state */
    sys->runtime[WIPER_FRONT].ignition_active =
        HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_IGNITION);
    sys->runtime[WIPER_REAR].ignition_active =
        sys->runtime[WIPER_FRONT].ignition_active;

    /* Process park switch with debouncing */
    raw_state = HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_PARK_SW_A);
    if (raw_state != sys->runtime[WIPER_FRONT].park_switch_active) {
        if (Util_ElapsedTime(sys->runtime[WIPER_FRONT].park_debounce_time, current_time)
            >= sys->config.position_config.park_switch_debounce_ms) {
            sys->runtime[WIPER_FRONT].park_switch_debounced = raw_state;
            sys->runtime[WIPER_FRONT].park_switch_active = raw_state;
        }
    } else {
        sys->runtime[WIPER_FRONT].park_debounce_time = current_time;
    }

    raw_state = HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_PARK_SW_B);
    if (raw_state != sys->runtime[WIPER_REAR].park_switch_active) {
        if (Util_ElapsedTime(sys->runtime[WIPER_REAR].park_debounce_time, current_time)
            >= sys->config.position_config.park_switch_debounce_ms) {
            sys->runtime[WIPER_REAR].park_switch_debounced = raw_state;
            sys->runtime[WIPER_REAR].park_switch_active = raw_state;
        }
    } else {
        sys->runtime[WIPER_REAR].park_debounce_time = current_time;
    }

    /* Process buttons */
    Button_Process(&sys->inputs.mode_switch,
                   HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_MODE_SW),
                   current_time);
    Button_Process(&sys->inputs.intermittent_up,
                   HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_INT_UP),
                   current_time);
    Button_Process(&sys->inputs.intermittent_down,
                   HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_INT_DOWN),
                   current_time);
    Button_Process(&sys->inputs.wash_button,
                   HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_WASH_BTN),
                   current_time);
    Button_Process(&sys->inputs.service_button,
                   HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_SERVICE_BTN),
                   current_time);

    /* Determine requested mode */
    sys->runtime[WIPER_FRONT].requested_mode = Input_DetermineRequestedMode(sys);

    /* Process intermittent level adjustment */
    sys->runtime[WIPER_FRONT].intermittent_level = Input_GetIntermittentLevel(sys);

    /* Classify vehicle speed */
    sys->runtime[WIPER_FRONT].vehicle_speed_range =
        Input_ClassifyVehicleSpeed(sys->runtime[WIPER_FRONT].vehicle_speed_kmh);
}

static void Button_Process(ButtonState_t *btn, bool raw_input, uint32_t current_time)
{
    if (btn == NULL) {
        return;
    }

    btn->raw_state = raw_input;
    btn->pressed  = false;
    btn->released = false;

    /* Debounce logic */
    if (raw_input == btn->debounced_state) {
        btn->debounce_counter = 0;
    } else {
        btn->debounce_counter++;
        if (btn->debounce_counter >= btn->debounce_threshold) {
            btn->prev_debounced_state = btn->debounced_state;
            btn->debounced_state = raw_input;
            btn->debounce_counter = 0;

            if (btn->debounced_state && !btn->prev_debounced_state) {
                btn->pressed = true;
                btn->press_time = current_time;
            } else if (!btn->debounced_state && btn->prev_debounced_state) {
                btn->released = true;
                btn->release_time = current_time;
            }
        }
    }

    /* Track hold duration */
    if (btn->debounced_state) {
        btn->hold_duration = Util_ElapsedTime(btn->press_time, current_time);
        btn->held = (btn->hold_duration > 500);
    } else {
        btn->hold_duration = 0;
        btn->held = false;
    }
}

static WiperMode_t Input_DetermineRequestedMode(WiperSystem_t *sys)
{
    WiperMode_t requested;
    WiperMode_t current;

    current = sys->runtime[WIPER_FRONT].current_mode;
    requested = current;

    /* Check for wash button (highest priority) */
    if (sys->inputs.wash_button.pressed) {
        return WIPER_MODE_WASH;
    }

    /* Check for service mode (held button) */
    if (sys->inputs.service_button.held &&
        sys->inputs.service_button.hold_duration > 3000) {
        return WIPER_MODE_SERVICE;
    }

    /* Check mode switch for cycling through modes */
    if (sys->inputs.mode_switch.pressed) {
        switch (current) {
            case WIPER_MODE_OFF:
                requested = WIPER_MODE_INTERMITTENT;
                break;
            case WIPER_MODE_INTERMITTENT:
                requested = WIPER_MODE_LOW;
                break;
            case WIPER_MODE_LOW:
                requested = WIPER_MODE_HIGH;
                break;
            case WIPER_MODE_HIGH:
                requested = WIPER_MODE_AUTO;
                break;
            case WIPER_MODE_AUTO:
                requested = WIPER_MODE_OFF;
                break;
            case WIPER_MODE_WASH:
                /* During wash, mode switch is ignored */
                requested = current;
                break;
            case WIPER_MODE_SERVICE:
                requested = WIPER_MODE_OFF;
                break;
            default:
                requested = WIPER_MODE_OFF;
                break;
        }
    }

    /* Ignition check */
    if (!sys->runtime[WIPER_FRONT].ignition_active &&
        requested != WIPER_MODE_OFF) {
        /* Allow only parking/off when ignition is off, unless service mode */
        if (requested != WIPER_MODE_SERVICE) {
            requested = WIPER_MODE_OFF;
        }
    }

    return requested;
}

static uint8_t Input_GetIntermittentLevel(WiperSystem_t *sys)
{
    uint8_t level;

    level = sys->runtime[WIPER_FRONT].intermittent_level;

    if (sys->inputs.intermittent_up.pressed) {
        if (level < 6) {
            level++;
        }
    }

    if (sys->inputs.intermittent_down.pressed) {
        if (level > 1) {
            level--;
        }
    }

    return level;
}

static VehicleSpeedRange_t Input_ClassifyVehicleSpeed(uint16_t speed_kmh)
{
    if (speed_kmh < 5) {
        return VEHICLE_SPEED_PARKED;
    } else if (speed_kmh < 80) {
        return VEHICLE_SPEED_CITY;
    } else {
        return VEHICLE_SPEED_HIGHWAY;
    }
}

/*=============================================================================
 * SECTION 17: MOTOR CONTROL FUNCTIONS
 *===========================================================================*/

static void Motor_SetDirection(WiperSystem_t *sys, WiperChannel_t ch,
                               MotorDirection_t dir)
{
    uint8_t pin_fwd;
    uint8_t pin_rev;

    pin_fwd = (ch == WIPER_FRONT) ? GPIO_PIN_MOTOR_FWD_A : GPIO_PIN_MOTOR_FWD_B;
    pin_rev = (ch == WIPER_FRONT) ? GPIO_PIN_MOTOR_REV_A : GPIO_PIN_MOTOR_REV_B;

    switch (dir) {
        case MOTOR_DIR_STOP:
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_fwd, false);
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_rev, false);
            break;
        case MOTOR_DIR_FORWARD:
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_fwd, true);
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_rev, false);
            break;
        case MOTOR_DIR_REVERSE:
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_fwd, false);
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_rev, true);
            break;
        case MOTOR_DIR_BRAKE:
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_fwd, true);
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_rev, true);
            break;
        default:
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_fwd, false);
            HAL_GPIO_WritePin(GPIO_PORT_MOTOR, pin_rev, false);
            break;
    }

    sys->motor[ch].direction = dir;

    if (dir == MOTOR_DIR_FORWARD || dir == MOTOR_DIR_REVERSE) {
        if (!sys->motor[ch].is_running) {
            sys->motor[ch].is_running  = true;
            sys->motor[ch].start_time  = sys->system_tick_ms;
        }
    } else {
        if (sys->motor[ch].is_running) {
            sys->motor[ch].runtime_ms += Util_ElapsedTime(
                sys->motor[ch].start_time, sys->system_tick_ms);
            sys->motor[ch].is_running = false;
        }
    }
}

static void Motor_SetSpeed(WiperSystem_t *sys, WiperChannel_t ch, uint16_t pwm_duty)
{
    uint8_t pwm_channel;

    pwm_duty = Util_Clamp16(pwm_duty, 0, 1000);

    sys->motor[ch].target_pwm = pwm_duty;
    pwm_channel = (ch == WIPER_FRONT) ? PWM_CH_MOTOR_A : PWM_CH_MOTOR_B;

    /* Apply speed profile */
    switch (sys->config.speed_profile) {
        case SPEED_PROFILE_LINEAR:
            sys->motor[ch].current_pwm = pwm_duty;
            HAL_PWM_SetDuty(pwm_channel, pwm_duty);
            break;

        case SPEED_PROFILE_RAMP:
        case SPEED_PROFILE_SCURVE:
            /* Ramping handled in Motor_UpdateRamp */
            break;

        default:
            sys->motor[ch].current_pwm = pwm_duty;
            HAL_PWM_SetDuty(pwm_channel, pwm_duty);
            break;
    }

    if (pwm_duty > 0) {
        HAL_PWM_Start(pwm_channel);
    }
}

static void Motor_Stop(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint8_t pwm_channel;

    pwm_channel = (ch == WIPER_FRONT) ? PWM_CH_MOTOR_A : PWM_CH_MOTOR_B;

    HAL_PWM_SetDuty(pwm_channel, 0);
    HAL_PWM_Stop(pwm_channel);
    Motor_SetDirection(sys, ch, MOTOR_DIR_STOP);

    sys->motor[ch].current_pwm = 0;
    sys->motor[ch].target_pwm  = 0;
}

static void Motor_Brake(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint8_t pwm_channel;

    pwm_channel = (ch == WIPER_FRONT) ? PWM_CH_MOTOR_A : PWM_CH_MOTOR_B;

    HAL_PWM_SetDuty(pwm_channel, 0);
    HAL_PWM_Stop(pwm_channel);
    Motor_SetDirection(sys, ch, MOTOR_DIR_BRAKE);

    sys->motor[ch].current_pwm = 0;
    sys->motor[ch].target_pwm  = 0;
}

static void Motor_UpdateRamp(WiperSystem_t *sys, WiperChannel_t ch)
{
    MotorControl_t *motor;
    uint8_t pwm_channel;
    int32_t diff;
    uint16_t step;

    motor = &sys->motor[ch];
    pwm_channel = (ch == WIPER_FRONT) ? PWM_CH_MOTOR_A : PWM_CH_MOTOR_B;

    if (motor->current_pwm == motor->target_pwm) {
        return;
    }

    diff = (int32_t)motor->target_pwm - (int32_t)motor->current_pwm;
    step = motor->ramp_step;

    if (step == 0) {
        step = 10; /* Default step size */
    }

    if (diff > 0) {
        /* Ramping up */
        if ((uint16_t)diff <= step) {
            motor->current_pwm = motor->target_pwm;
        } else {
            motor->current_pwm += step;
        }
    } else {
        /* Ramping down */
        if (Util_AbsDiff16(motor->current_pwm, motor->target_pwm) <= step) {
            motor->current_pwm = motor->target_pwm;
        } else {
            motor->current_pwm -= step;
        }
    }

    HAL_PWM_SetDuty(pwm_channel, motor->current_pwm);
}

static uint16_t Motor_CalculateRampStep(uint16_t target, uint16_t current,
                                        uint16_t ramp_time_ms, uint32_t period_ms)
{
    uint16_t diff;
    uint32_t steps;
    uint16_t step_size;

    diff = Util_AbsDiff16(target, current);
    if (ramp_time_ms == 0 || period_ms == 0) {
        return diff;
    }

    steps = ramp_time_ms / period_ms;
    if (steps == 0) {
        steps = 1;
    }

    step_size = diff / (uint16_t)steps;
    if (step_size == 0) {
        step_size = 1;
    }

    return step_size;
}

static bool Motor_IsAtPosition(WiperSystem_t *sys, WiperChannel_t ch,
                                WiperPosition_t pos)
{
    uint16_t current_pos;
    uint16_t target_pos;
    uint16_t tolerance;

    current_pos = sys->position_sensor[ch].filtered_value;
    tolerance   = sys->config.position_config.position_tolerance;

    switch (pos) {
        case WIPER_POSITION_PARK:
            target_pos = sys->config.position_config.park_position_adc;
            /* Also check park switch for confirmation */
            if (sys->runtime[ch].park_switch_debounced) {
                return true;
            }
            break;
        case WIPER_POSITION_MAX:
            target_pos = sys->config.position_config.max_position_adc;
            break;
        case WIPER_POSITION_MIN:
            target_pos = sys->config.position_config.park_position_adc;
            break;
        default:
            return false;
    }

    return Util_InRange(current_pos, target_pos, tolerance);
}

static uint16_t Motor_GetSpeedForMode(WiperSystem_t *sys, WiperMode_t mode)
{
    uint16_t speed;

    switch (mode) {
        case WIPER_MODE_LOW:
            speed = sys->config.speed_low.motor_pwm_duty;
            break;
        case WIPER_MODE_HIGH:
            speed = sys->config.speed_high.motor_pwm_duty;
            break;
        case WIPER_MODE_INTERMITTENT:
            speed = sys->config.intermittent_settings[
                sys->runtime[WIPER_FRONT].rain_intensity].motor_pwm_duty;
            break;
        case WIPER_MODE_WASH:
            speed = sys->config.speed_low.motor_pwm_duty;
            break;
        default:
            speed = 0;
            break;
    }

    return speed;
}

/*=============================================================================
 * SECTION 18: WASHER CONTROL
 *===========================================================================*/

static void Washer_PumpOn(WiperSystem_t *sys, uint16_t pwm_duty)
{
    HAL_PWM_SetDuty(PWM_CH_WASH_PUMP, pwm_duty);
    HAL_PWM_Start(PWM_CH_WASH_PUMP);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_WASH_PUMP, true);

    (void)sys;
}

static void Washer_PumpOff(WiperSystem_t *sys)
{
    HAL_PWM_SetDuty(PWM_CH_WASH_PUMP, 0);
    HAL_PWM_Stop(PWM_CH_WASH_PUMP);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_WASH_PUMP, false);

    (void)sys;
}

static bool Washer_IsFluidAvailable(WiperSystem_t *sys)
{
    bool level_ok;

    level_ok = HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_WASH_LEVEL);

    if (!level_ok) {
        Fault_SetFault(sys, FAULT_WASHER_LEVEL);
    }

    return level_ok;
}

/*=============================================================================
 * SECTION 19: STATE MACHINE - MAIN PROCESSOR
 *===========================================================================*/

static void StateMachine_Process(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt;
    WiperMode_t auto_mode;

    if (sys == NULL) {
        return;
    }

    rt = &sys->runtime[ch];

    /* Update state elapsed time */
    rt->state_elapsed_time = Util_ElapsedTime(rt->state_entry_time, sys->system_tick_ms);

    /* Handle mode transitions */
    if (rt->requested_mode != rt->current_mode) {
        /* Mode change requested */
        if (rt->current_state != WIPER_STATE_FAULT) {
            switch (rt->requested_mode) {
                case WIPER_MODE_OFF:
                    if (rt->current_state != WIPER_STATE_PARKING &&
                        rt->current_state != WIPER_STATE_IDLE) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_PARKING);
                    }
                    rt->current_mode = WIPER_MODE_OFF;
                    break;

                case WIPER_MODE_INTERMITTENT:
                    rt->current_mode = WIPER_MODE_INTERMITTENT;
                    if (rt->current_state == WIPER_STATE_IDLE) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_INTERMITTENT_PAUSE);
                    }
                    break;

                case WIPER_MODE_LOW:
                    rt->current_mode = WIPER_MODE_LOW;
                    if (rt->current_state == WIPER_STATE_IDLE ||
                        rt->current_state == WIPER_STATE_INTERMITTENT_PAUSE) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
                    }
                    break;

                case WIPER_MODE_HIGH:
                    rt->current_mode = WIPER_MODE_HIGH;
                    if (rt->current_state == WIPER_STATE_IDLE ||
                        rt->current_state == WIPER_STATE_INTERMITTENT_PAUSE) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
                    }
                    break;

                case WIPER_MODE_AUTO:
                    rt->current_mode = WIPER_MODE_AUTO;
                    break;

                case WIPER_MODE_WASH:
                    rt->current_mode = WIPER_MODE_WASH;
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_WASH_SPRAY);
                    break;

                case WIPER_MODE_SERVICE:
                    rt->current_mode = WIPER_MODE_SERVICE;
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_SERVICE_POSITION);
                    break;

                default:
                    break;
            }
        }
    }

    /* Handle auto mode rain-based adjustments */
    if (rt->current_mode == WIPER_MODE_AUTO && ch == WIPER_FRONT) {
        RainIntensity_t new_intensity = Rain_ClassifyIntensity(sys);

        if (new_intensity != rt->rain_intensity) {
            /* Apply debounce to rain intensity changes */
            if (rt->prev_rain_intensity != new_intensity) {
                rt->prev_rain_intensity = new_intensity;
                rt->rain_change_time = sys->system_tick_ms;
            } else if (Util_ElapsedTime(rt->rain_change_time, sys->system_tick_ms) > 1000) {
                rt->rain_intensity = new_intensity;

                auto_mode = Rain_DetermineAutoMode(sys, new_intensity);

                /* Apply auto mode logic */
                if (auto_mode == WIPER_MODE_OFF) {
                    if (rt->current_state != WIPER_STATE_IDLE &&
                        rt->current_state != WIPER_STATE_PARKING) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_PARKING);
                    }
                } else if (auto_mode == WIPER_MODE_INTERMITTENT) {
                    if (rt->current_state == WIPER_STATE_IDLE) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_INTERMITTENT_PAUSE);
                    }
                } else {
                    if (rt->current_state == WIPER_STATE_IDLE ||
                        rt->current_state == WIPER_STATE_INTERMITTENT_PAUSE) {
                        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
                    }
                }
            }
        } else {
            rt->prev_rain_intensity = new_intensity;
        }
    }

    /* Check for critical faults */
    if (Fault_IsCritical(sys) && rt->current_state != WIPER_STATE_FAULT) {
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_FAULT);
    }

    /* Execute current state */
    switch (rt->current_state) {
        case WIPER_STATE_IDLE:
            State_Idle_Execute(sys, ch);
            break;
        case WIPER_STATE_PARKING:
            State_Parking_Execute(sys, ch);
            break;
        case WIPER_STATE_SWEEP_FORWARD:
            State_SweepForward_Execute(sys, ch);
            break;
        case WIPER_STATE_SWEEP_REVERSE:
            State_SweepReverse_Execute(sys, ch);
            break;
        case WIPER_STATE_INTERMITTENT_PAUSE:
            State_IntermittentPause_Execute(sys, ch);
            break;
        case WIPER_STATE_WASH_SPRAY:
            State_WashSpray_Execute(sys, ch);
            break;
        case WIPER_STATE_WASH_WIPE:
            State_WashWipe_Execute(sys, ch);
            break;
        case WIPER_STATE_WASH_FINAL:
            State_WashFinal_Execute(sys, ch);
            break;
        case WIPER_STATE_FAULT:
            State_Fault_Execute(sys, ch);
            break;
        case WIPER_STATE_SERVICE_POSITION:
            State_ServicePosition_Execute(sys, ch);
            break;
        default:
            StateMachine_TransitionTo(sys, ch, WIPER_STATE_IDLE);
            break;
    }

    /* Update motor ramp in every cycle */
    Motor_UpdateRamp(sys, ch);
}

static void StateMachine_TransitionTo(WiperSystem_t *sys, WiperChannel_t ch,
                                      WiperState_t new_state)
{
    WiperRuntime_t *rt;

    rt = &sys->runtime[ch];
    rt->previous_state   = rt->current_state;
    rt->current_state    = new_state;
    rt->state_entry_time = sys->system_tick_ms;
    rt->state_elapsed_time = 0;

    /* Execute entry actions for new state */
    switch (new_state) {
        case WIPER_STATE_IDLE:
            State_Idle_Entry(sys, ch);
            break;
        case WIPER_STATE_PARKING:
            State_Parking_Entry(sys, ch);
            break;
        case WIPER_STATE_SWEEP_FORWARD:
            State_SweepForward_Entry(sys, ch);
            break;
        case WIPER_STATE_SWEEP_REVERSE:
            State_SweepReverse_Entry(sys, ch);
            break;
        case WIPER_STATE_INTERMITTENT_PAUSE:
            State_IntermittentPause_Entry(sys, ch);
            break;
        case WIPER_STATE_WASH_SPRAY:
            State_WashSpray_Entry(sys, ch);
            break;
        case WIPER_STATE_WASH_WIPE:
            State_WashWipe_Entry(sys, ch);
            break;
        case WIPER_STATE_WASH_FINAL:
            State_WashFinal_Entry(sys, ch);
            break;
        case WIPER_STATE_FAULT:
            State_Fault_Entry(sys, ch);
            break;
        case WIPER_STATE_SERVICE_POSITION:
            State_ServicePosition_Entry(sys, ch);
            break;
        default:
            break;
    }
}

/*=============================================================================
 * SECTION 20: STATE HANDLER IMPLEMENTATIONS
 *===========================================================================*/

static void State_Idle_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    Motor_Stop(sys, ch);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, false);
}

static void State_Idle_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* In idle, check if any active mode requires action */
    if (rt->current_mode == WIPER_MODE_LOW ||
        rt->current_mode == WIPER_MODE_HIGH) {
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
    } else if (rt->current_mode == WIPER_MODE_INTERMITTENT) {
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_INTERMITTENT_PAUSE);
    }

    /* Status LED: slow blink in idle with ignition on */
    if (rt->ignition_active) {
        bool led_state = ((sys->system_tick_ms / 1000) % 2) == 0;
        HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, led_state);
    }
}

static void State_Parking_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint16_t park_speed;

    /* Drive to park position at reduced speed */
    park_speed = sys->config.speed_low.motor_pwm_duty / 2;
    if (park_speed < 300) {
        park_speed = 300;
    }

    /* Determine direction to park */
    if (sys->runtime[ch].current_position > sys->config.position_config.park_position_adc) {
        Motor_SetDirection(sys, ch, MOTOR_DIR_REVERSE);
    } else {
        Motor_SetDirection(sys, ch, MOTOR_DIR_FORWARD);
    }

    sys->motor[ch].ramp_step = Motor_CalculateRampStep(
        park_speed, sys->motor[ch].current_pwm,
        sys->config.speed_low.ramp_down_time_ms,
        sys->config.main_task_period_ms);
    Motor_SetSpeed(sys, ch, park_speed);
}

static void State_Parking_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Check if at park position */
    if (Motor_IsAtPosition(sys, ch, WIPER_POSITION_PARK) ||
        rt->park_switch_debounced) {
        Motor_Brake(sys, ch);
        HAL_DelayMs(50);
        Motor_Stop(sys, ch);

        sys->motor[ch].total_cycles++;
        sys->statistics.total_wipe_cycles++;

        StateMachine_TransitionTo(sys, ch, WIPER_STATE_IDLE);
        return;
    }

    /* Timeout check for parking */
    if (rt->state_elapsed_time > sys->config.fault_config.position_timeout_ms) {
        Fault_SetFault(sys, FAULT_PARK_SWITCH);
        Motor_Stop(sys, ch);
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_FAULT);
    }
}

static void State_SweepForward_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint16_t speed;
    SpeedConfig_t *speed_cfg;

    Motor_SetDirection(sys, ch, MOTOR_DIR_FORWARD);

    speed = Motor_GetSpeedForMode(sys, sys->runtime[ch].current_mode);

    if (sys->runtime[ch].current_mode == WIPER_MODE_HIGH) {
        speed_cfg = &sys->config.speed_high;
    } else {
        speed_cfg = &sys->config.speed_low;
    }

    sys->motor[ch].ramp_step = Motor_CalculateRampStep(
        speed, sys->motor[ch].current_pwm,
        speed_cfg->ramp_up_time_ms,
        sys->config.main_task_period_ms);
    Motor_SetSpeed(sys, ch, speed);

    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, true);
}

static void State_SweepForward_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Check if reached max position */
    if (Motor_IsAtPosition(sys, ch, WIPER_POSITION_MAX)) {
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_REVERSE);
        return;
    }

    /* Dynamically adjust speed if mode changed (e.g., LOW to HIGH) */
    if (rt->current_mode == WIPER_MODE_LOW || rt->current_mode == WIPER_MODE_HIGH) {
        uint16_t target_speed = Motor_GetSpeedForMode(sys, rt->current_mode);
        if (sys->motor[ch].target_pwm != target_speed) {
            sys->motor[ch].ramp_step = Motor_CalculateRampStep(
                target_speed, sys->motor[ch].current_pwm,
                200, sys->config.main_task_period_ms);
            Motor_SetSpeed(sys, ch, target_speed);
        }
    }

    /* Position timeout */
    if (rt->state_elapsed_time > sys->config.fault_config.position_timeout_ms) {
        Fault_SetFault(sys, FAULT_MOTOR_STALL);
        Motor_Stop(sys, ch);
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_FAULT);
    }
}

static void State_SweepReverse_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint16_t speed;
    SpeedConfig_t *speed_cfg;

    Motor_SetDirection(sys, ch, MOTOR_DIR_REVERSE);

    speed = Motor_GetSpeedForMode(sys, sys->runtime[ch].current_mode);

    if (sys->runtime[ch].current_mode == WIPER_MODE_HIGH) {
        speed_cfg = &sys->config.speed_high;
    } else {
        speed_cfg = &sys->config.speed_low;
    }

    sys->motor[ch].ramp_step = Motor_CalculateRampStep(
        speed, sys->motor[ch].current_pwm,
        speed_cfg->ramp_up_time_ms,
        sys->config.main_task_period_ms);
    Motor_SetSpeed(sys, ch, speed);
}

static void State_SweepReverse_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Check if reached park position */
    if (Motor_IsAtPosition(sys, ch, WIPER_POSITION_PARK) ||
        rt->park_switch_debounced) {

        Motor_Brake(sys, ch);
        HAL_DelayMs(20);
        Motor_Stop(sys, ch);

        sys->motor[ch].total_cycles++;
        sys->statistics.total_wipe_cycles++;

        /* Determine next state based on mode */
        switch (rt->current_mode) {
            case WIPER_MODE_OFF:
                StateMachine_TransitionTo(sys, ch, WIPER_STATE_IDLE);
                break;

            case WIPER_MODE_INTERMITTENT:
                StateMachine_TransitionTo(sys, ch, WIPER_STATE_INTERMITTENT_PAUSE);
                break;

            case WIPER_MODE_LOW:
            case WIPER_MODE_HIGH:
                StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
                break;

            case WIPER_MODE_AUTO: {
                WiperMode_t auto_mode = Rain_DetermineAutoMode(sys, rt->rain_intensity);
                if (auto_mode == WIPER_MODE_OFF) {
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_IDLE);
                } else if (auto_mode == WIPER_MODE_INTERMITTENT) {
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_INTERMITTENT_PAUSE);
                } else {
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
                }
                break;
            }

            case WIPER_MODE_WASH:
                /* Wash wipe cycle completion */
                rt->wash_wipe_counter++;
                if (rt->wash_wipe_counter >= sys->config.wash_config.wipe_count) {
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_WASH_FINAL);
                } else {
                    StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
                }
                break;

            default:
                StateMachine_TransitionTo(sys, ch, WIPER_STATE_IDLE);
                break;
        }
        return;
    }

    /* Position timeout */
    if (rt->state_elapsed_time > sys->config.fault_config.position_timeout_ms) {
        Fault_SetFault(sys, FAULT_MOTOR_STALL);
        Motor_Stop(sys, ch);
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_FAULT);
    }
}

static void State_IntermittentPause_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    Motor_Stop(sys, ch);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, false);
}

static void State_IntermittentPause_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];
    uint32_t interval;
    RainIntensity_t intensity;

    /* Determine interval based on current rain intensity and settings */
    if (rt->current_mode == WIPER_MODE_AUTO) {
        intensity = rt->rain_intensity;
    } else {
        /* For manual intermittent, use LIGHT as baseline */
        intensity = RAIN_INTENSITY_LIGHT;
    }

    interval = Rain_GetIntermittentInterval(sys, intensity);

    /* Blink LED during pause */
    if ((rt->state_elapsed_time / 500) % 2) {
        HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, true);
    } else {
        HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, false);
    }

    /* Check if pause time has elapsed */
    if (rt->state_elapsed_time >= interval) {
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
    }

    /* If mode changed to OFF during pause */
    if (rt->current_mode == WIPER_MODE_OFF) {
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_IDLE);
    }
}

static void State_WashSpray_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    rt->wash_wipe_counter = 0;

    /* Check washer fluid level */
    if (Washer_IsFluidAvailable(sys)) {
        Washer_PumpOn(sys, sys->config.wash_config.pump_pwm_duty);
    } else {
        /* No fluid, skip to wipe only */
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_WASH_WIPE);
    }

    sys->statistics.total_wash_cycles++;
}

static void State_WashSpray_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Wait for spray duration */
    if (rt->state_elapsed_time >= sys->config.wash_config.spray_duration_ms) {
        Washer_PumpOff(sys);
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_WASH_WIPE);
    }

    /* Status LED: rapid blink during spray */
    bool led = ((sys->system_tick_ms / 100) % 2) == 0;
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, led);
}

static void State_WashWipe_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    /* Start wipe cycle */
    Motor_SetDirection(sys, ch, MOTOR_DIR_FORWARD);

    uint16_t speed = sys->config.speed_low.motor_pwm_duty;
    sys->motor[ch].ramp_step = Motor_CalculateRampStep(
        speed, 0, sys->config.speed_low.ramp_up_time_ms,
        sys->config.main_task_period_ms);
    Motor_SetSpeed(sys, ch, speed);
}

static void State_WashWipe_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    /* During wash wipe, use the sweep forward/reverse logic */
    /* Check if reached max position */
    if (Motor_IsAtPosition(sys, ch, WIPER_POSITION_MAX)) {
        Motor_SetDirection(sys, ch, MOTOR_DIR_REVERSE);
        return;
    }

    /* Check if back at park */
    if (sys->motor[ch].direction == MOTOR_DIR_REVERSE &&
        (Motor_IsAtPosition(sys, ch, WIPER_POSITION_PARK) ||
         sys->runtime[ch].park_switch_debounced)) {

        Motor_Brake(sys, ch);
        HAL_DelayMs(20);
        Motor_Stop(sys, ch);

        sys->runtime[ch].wash_wipe_counter++;
        sys->motor[ch].total_cycles++;

        if (sys->runtime[ch].wash_wipe_counter >= sys->config.wash_config.wipe_count) {
            StateMachine_TransitionTo(sys, ch, WIPER_STATE_WASH_FINAL);
        } else {
            /* Start another wipe */
            Motor_SetDirection(sys, ch, MOTOR_DIR_FORWARD);
            Motor_SetSpeed(sys, ch, sys->config.speed_low.motor_pwm_duty);
        }
    }

    /* Timeout */
    if (sys->runtime[ch].state_elapsed_time >
        sys->config.fault_config.position_timeout_ms * sys->config.wash_config.wipe_count) {
        Fault_SetFault(sys, FAULT_MOTOR_STALL);
        Motor_Stop(sys, ch);
        Washer_PumpOff(sys);
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_FAULT);
    }
}

static void State_WashFinal_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    Motor_Stop(sys, ch);
    Washer_PumpOff(sys);
}

static void State_WashFinal_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Wait for final delay then do a final wipe */
    if (rt->state_elapsed_time >= sys->config.wash_config.final_delay_ms) {
        /* One final wipe to clear remaining fluid */
        rt->current_mode = WIPER_MODE_OFF;
        rt->requested_mode = WIPER_MODE_OFF;
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_SWEEP_FORWARD);
    }
}

static void State_Fault_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    Motor_Stop(sys, ch);
    Washer_PumpOff(sys);

    sys->statistics.fault_event_count++;
}

static void State_Fault_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Fault LED indicator: rapid blink */
    bool led = ((sys->system_tick_ms / 200) % 2) == 0;
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, led);

    /* Attempt recovery after delay */
    if (rt->state_elapsed_time >= sys->config.fault_config.recovery_delay_ms) {
        Fault_AttemptRecovery(sys);

        if (!Fault_IsCritical(sys)) {
            /* Recovery successful */
            rt->current_mode = WIPER_MODE_OFF;
            rt->requested_mode = WIPER_MODE_OFF;
            StateMachine_TransitionTo(sys, ch, WIPER_STATE_PARKING);
        } else {
            /* Reset timer for next retry */
            rt->state_entry_time = sys->system_tick_ms;
        }
    }

    /* Force off mode in fault */
    rt->current_mode = WIPER_MODE_OFF;
}

static void State_ServicePosition_Entry(WiperSystem_t *sys, WiperChannel_t ch)
{
    /* Move wipers to service position (fully up) at slow speed */
    Motor_SetDirection(sys, ch, MOTOR_DIR_FORWARD);

    uint16_t speed = sys->config.speed_low.motor_pwm_duty / 2;
    sys->motor[ch].ramp_step = Motor_CalculateRampStep(
        speed, 0, 500, sys->config.main_task_period_ms);
    Motor_SetSpeed(sys, ch, speed);

    sys->runtime[ch].service_mode = true;
}

static void State_ServicePosition_Execute(WiperSystem_t *sys, WiperChannel_t ch)
{
    WiperRuntime_t *rt = &sys->runtime[ch];

    /* Move to approximately midpoint and hold */
    uint16_t service_pos = (sys->config.position_config.park_position_adc +
                            sys->config.position_config.max_position_adc) / 2;

    if (Util_InRange(rt->current_position, service_pos,
                     sys->config.position_config.position_tolerance * 2)) {
        Motor_Brake(sys, ch);
        Motor_Stop(sys, ch);
    }

    /* Exit service mode when button released or mode changed */
    if (rt->requested_mode != WIPER_MODE_SERVICE) {
        rt->service_mode = false;
        rt->current_mode = WIPER_MODE_OFF;
        StateMachine_TransitionTo(sys, ch, WIPER_STATE_PARKING);
    }

    /* Timeout protection */
    if (rt->state_elapsed_time > sys->config.fault_config.position_timeout_ms * 2) {
        Motor_Stop(sys, ch);
    }
}

/*=============================================================================
 * SECTION 21: FAULT MANAGEMENT
 *===========================================================================*/

static void Fault_ProcessAll(WiperSystem_t *sys)
{
    uint8_t ch;

    if (sys == NULL) {
        return;
    }

    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        Fault_CheckMotorCurrent(sys, (WiperChannel_t)ch);
        Fault_CheckMotorStall(sys, (WiperChannel_t)ch);
        Fault_CheckPositionSensor(sys, (WiperChannel_t)ch);
    }

    Fault_CheckRainSensor(sys);
    Fault_CheckTemperature(sys);
    Fault_CheckSupplyVoltage(sys);
}

static void Fault_CheckMotorCurrent(WiperSystem_t *sys, WiperChannel_t ch)
{
    uint16_t current_ma;
    uint16_t threshold;

    if (!sys->motor[ch].is_running) {
        return;
    }

    /* Convert ADC to milliamps (scaling depends on current sense circuit) */
    current_ma = (uint16_t)Util_Map(
        (int32_t)sys->current_sensor[ch].filtered_value,
        0, 4095, 0, 10000);

    threshold = sys->config.fault_config.overcurrent_threshold_ma;

    if (current_ma > threshold) {
        sys->fault_mgr.fault_counters[0]++;
        if (sys->fault_mgr.fault_counters[0] >= sys->config.fault_config.fault_debounce_count) {
            Fault_SetFault(sys, FAULT_MOTOR_OVERCURRENT);
        }
    } else {
        if (sys->fault_mgr.fault_counters[0] > 0) {
            sys->fault_mgr.fault_counters[0]--;
        }
    }

    /* Track max current for statistics */
    if (current_ma > sys->statistics.max_motor_current_ma) {
        sys->statistics.max_motor_current_ma = current_ma;
    }
}

static void Fault_CheckMotorStall(WiperSystem_t *sys, WiperChannel_t ch)
{
    MotorControl_t *motor;
    SensorData_t *pos;
    static uint16_t last_position[WIPER_CHANNEL_COUNT] = {0};
    static uint32_t last_check_time[WIPER_CHANNEL_COUNT] = {0};

    motor = &sys->motor[ch];
    pos   = &sys->position_sensor[ch];

    if (!motor->is_running || motor->current_pwm < 100) {
        last_position[ch] = pos->filtered_value;
        last_check_time[ch] = sys->system_tick_ms;
        return;
    }

    /* Check every 500ms if position has changed */
    if (Util_ElapsedTime(last_check_time[ch], sys->system_tick_ms) >= 500) {
        uint16_t pos_change = Util_AbsDiff16(pos->filtered_value, last_position[ch]);

        if (pos_change < 20) {
            /* Motor running but position not changing - potential stall */
            sys->fault_mgr.fault_counters[1]++;
            if (sys->fault_mgr.fault_counters[1] >=
                (sys->config.fault_config.stall_timeout_ms / 500)) {
                Fault_SetFault(sys, FAULT_MOTOR_STALL);
            }
        } else {
            sys->fault_mgr.fault_counters[1] = 0;
        }

        last_position[ch] = pos->filtered_value;
        last_check_time[ch] = sys->system_tick_ms;
    }
}

static void Fault_CheckPositionSensor(WiperSystem_t *sys, WiperChannel_t ch)
{
    SensorData_t *pos;

    pos = &sys->position_sensor[ch];

    if (!pos->valid) {
        sys->fault_mgr.fault_counters[2]++;
        if (sys->fault_mgr.fault_counters[2] >= sys->config.fault_config.fault_debounce_count * 5) {
            Fault_SetFault(sys, FAULT_POSITION_SENSOR);
        }
    } else {
        if (sys->fault_mgr.fault_counters[2] > 0) {
            sys->fault_mgr.fault_counters[2]--;
        }
    }
}

static void Fault_CheckRainSensor(WiperSystem_t *sys)
{
    SensorData_t *rain;

    rain = &sys->rain_sensor;

    if (!rain->valid) {
        sys->fault_mgr.fault_counters[3]++;
        if (sys->fault_mgr.fault_counters[3] >= sys->config.fault_config.fault_debounce_count * 10) {
            Fault_SetFault(sys, FAULT_RAIN_SENSOR);
        }
    } else {
        if (sys->fault_mgr.fault_counters[3] > 0) {
            sys->fault_mgr.fault_counters[3]--;
        }

        /* Clear rain sensor fault if sensor becomes valid again */
        if (Fault_IsActive(sys, FAULT_RAIN_SENSOR) && sys->fault_mgr.fault_counters[3] == 0) {
            Fault_ClearFault(sys, FAULT_RAIN_SENSOR);
        }
    }
}

static void Fault_CheckTemperature(WiperSystem_t *sys)
{
    uint16_t temp_c;

    if (!sys->temperature_sensor.valid) {
        return;
    }

    /* Convert ADC to temperature (depends on sensor circuit) */
    temp_c = (uint16_t)Util_Map(
        (int32_t)sys->temperature_sensor.filtered_value,
        0, 4095, -40, 150);

    if (temp_c > sys->config.fault_config.overtemp_threshold_c) {
        sys->fault_mgr.fault_counters[4]++;
        if (sys->fault_mgr.fault_counters[4] >= sys->config.fault_config.fault_debounce_count * 3) {
            Fault_SetFault(sys, FAULT_MOTOR_OVERTEMP);
        }
    } else {
        if (sys->fault_mgr.fault_counters[4] > 0) {
            sys->fault_mgr.fault_counters[4]--;
        }
        /* Auto-clear temperature fault when cooled down */
        if (temp_c < (sys->config.fault_config.overtemp_threshold_c - 10)) {
            Fault_ClearFault(sys, FAULT_MOTOR_OVERTEMP);
        }
    }

    if (temp_c > sys->statistics.max_temperature_c) {
        sys->statistics.max_temperature_c = temp_c;
    }
}

static void Fault_CheckSupplyVoltage(WiperSystem_t *sys)
{
    uint16_t voltage_mv;

    if (!sys->voltage_sensor.valid) {
        return;
    }

    /* Convert ADC to millivolts */
    voltage_mv = (uint16_t)Util_Map(
        (int32_t)sys->voltage_sensor.filtered_value,
        0, 4095, 0, 20000);

    if (voltage_mv < sys->config.fault_config.min_supply_voltage_mv ||
        voltage_mv > sys->config.fault_config.max_supply_voltage_mv) {
        sys->fault_mgr.fault_counters[5]++;
        if (sys->fault_mgr.fault_counters[5] >= sys->config.fault_config.fault_debounce_count * 5) {
            Fault_SetFault(sys, FAULT_SUPPLY_VOLTAGE);
        }
    } else {
        if (sys->fault_mgr.fault_counters[5] > 0) {
            sys->fault_mgr.fault_counters[5]--;
        }
        /* Clear voltage fault when back in range */
        if (voltage_mv >= (sys->config.fault_config.min_supply_voltage_mv + 500) &&
            voltage_mv <= (sys->config.fault_config.max_supply_voltage_mv - 500)) {
            Fault_ClearFault(sys, FAULT_SUPPLY_VOLTAGE);
        }
    }
}

static void Fault_SetFault(WiperSystem_t *sys, FaultCode_t fault)
{
    uint8_t bit_index;

    HAL_EnterCritical();

    sys->fault_mgr.active_faults |= (uint16_t)fault;
    sys->fault_mgr.historical_faults |= (uint16_t)fault;

    /* Record timestamp */
    for (bit_index = 0; bit_index < 16; bit_index++) {
        if ((uint16_t)fault & (1U << bit_index)) {
            sys->fault_mgr.fault_timestamps[bit_index] = sys->system_tick_ms;
            break;
        }
    }

    HAL_ExitCritical();
}

static void Fault_ClearFault(WiperSystem_t *sys, FaultCode_t fault)
{
    HAL_EnterCritical();
    sys->fault_mgr.active_faults &= ~((uint16_t)fault);
    HAL_ExitCritical();
}

static bool Fault_IsActive(WiperSystem_t *sys, FaultCode_t fault)
{
    return (sys->fault_mgr.active_faults & (uint16_t)fault) != 0;
}

static bool Fault_IsCritical(WiperSystem_t *sys)
{
    uint16_t critical_mask;

    critical_mask = (uint16_t)FAULT_MOTOR_OVERCURRENT |
                    (uint16_t)FAULT_MOTOR_STALL |
                    (uint16_t)FAULT_MOTOR_OVERTEMP |
                    (uint16_t)FAULT_SUPPLY_VOLTAGE;

    return (sys->fault_mgr.active_faults & critical_mask) != 0;
}

static void Fault_AttemptRecovery(WiperSystem_t *sys)
{
    uint8_t bit_index;

    for (bit_index = 0; bit_index < 16; bit_index++) {
        if (sys->fault_mgr.active_faults & (1U << bit_index)) {
            if (sys->fault_mgr.retry_counters[bit_index] <
                sys->config.fault_config.max_retry_count) {
                sys->fault_mgr.retry_counters[bit_index]++;

                /* Reset the fault counter to allow fresh detection */
                sys->fault_mgr.fault_counters[bit_index] = 0;

                /* Clear the fault for retry */
                sys->fault_mgr.active_faults &= ~(1U << bit_index);
            }
        }
    }
}

/*=============================================================================
 * SECTION 22: DIAGNOSTICS
 *===========================================================================*/

static void Diagnostics_Process(WiperSystem_t *sys)
{
    if (sys == NULL) {
        return;
    }

    if (sys->diagnostics.pending_command != DIAG_CMD_NONE) {
        Diagnostics_HandleCommand(sys);
    }

    /* Handle actuator test timeout */
    if (sys->diagnostics.test_active) {
        if (Util_ElapsedTime(sys->diagnostics.test_start_time, sys->system_tick_ms)
            >= sys->diagnostics.test_duration_ms) {
            /* Stop test */
            Motor_Stop(sys, (WiperChannel_t)sys->diagnostics.test_channel);
            Washer_PumpOff(sys);
            sys->diagnostics.test_active = false;
        }
    }
}

static void Diagnostics_HandleCommand(WiperSystem_t *sys)
{
    switch (sys->diagnostics.pending_command) {
        case DIAG_CMD_READ_FAULTS:
            Diagnostics_ReadFaults(sys);
            break;
        case DIAG_CMD_CLEAR_FAULTS:
            Diagnostics_ClearFaults(sys);
            break;
        case DIAG_CMD_READ_STATUS:
            Diagnostics_ReadStatus(sys);
            break;
        case DIAG_CMD_READ_SENSORS:
            Diagnostics_ReadSensors(sys);
            break;
        case DIAG_CMD_ACTUATOR_TEST:
            Diagnostics_ActuatorTest(sys);
            break;
        case DIAG_CMD_READ_CONFIG:
            Diagnostics_ReadConfig(sys);
            break;
        case DIAG_CMD_WRITE_CONFIG:
            Diagnostics_WriteConfig(sys);
            break;
        case DIAG_CMD_RESET:
            System_Init(sys);
            break;
        default:
            break;
    }

    sys->diagnostics.pending_command = DIAG_CMD_NONE;
    sys->diagnostics.command_complete = true;
}

static void Diagnostics_ReadFaults(WiperSystem_t *sys)
{
    uint8_t *resp;
    uint16_t offset;
    uint8_t i;

    resp = sys->diagnostics.response_data;
    offset = 0;

    /* Active faults */
    resp[offset++] = (uint8_t)(sys->fault_mgr.active_faults >> 8);
    resp[offset++] = (uint8_t)(sys->fault_mgr.active_faults & 0xFF);

    /* Historical faults */
    resp[offset++] = (uint8_t)(sys->fault_mgr.historical_faults >> 8);
    resp[offset++] = (uint8_t)(sys->fault_mgr.historical_faults & 0xFF);

    /* Fault counters */
    for (i = 0; i < 10; i++) {
        resp[offset++] = (uint8_t)(sys->fault_mgr.fault_counters[i] >> 8);
        resp[offset++] = (uint8_t)(sys->fault_mgr.fault_counters[i] & 0xFF);
    }

    sys->diagnostics.response_length = offset;
}

static void Diagnostics_ClearFaults(WiperSystem_t *sys)
{
    uint8_t i;

    HAL_EnterCritical();
    sys->fault_mgr.active_faults = 0;
    sys->fault_mgr.historical_faults = 0;

    for (i = 0; i < 16; i++) {
        sys->fault_mgr.fault_counters[i] = 0;
        sys->fault_mgr.fault_timestamps[i] = 0;
        sys->fault_mgr.retry_counters[i] = 0;
    }
    HAL_ExitCritical();

    sys->diagnostics.response_data[0] = 0x01; /* Success */
    sys->diagnostics.response_length = 1;
}

static void Diagnostics_ReadStatus(WiperSystem_t *sys)
{
    uint8_t *resp;
    uint16_t offset;
    uint8_t ch;

    resp = sys->diagnostics.response_data;
    offset = 0;

    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        resp[offset++] = (uint8_t)sys->runtime[ch].current_mode;
        resp[offset++] = (uint8_t)sys->runtime[ch].current_state;
        resp[offset++] = (uint8_t)sys->runtime[ch].rain_intensity;
        resp[offset++] = sys->runtime[ch].intermittent_level;
        resp[offset++] = (uint8_t)(sys->runtime[ch].current_position >> 8);
        resp[offset++] = (uint8_t)(sys->runtime[ch].current_position & 0xFF);
        resp[offset++] = (uint8_t)sys->motor[ch].direction;
        resp[offset++] = (uint8_t)(sys->motor[ch].current_pwm >> 8);
        resp[offset++] = (uint8_t)(sys->motor[ch].current_pwm & 0xFF);
        resp[offset++] = sys->motor[ch].is_running ? 1 : 0;
    }

    /* System info */
    resp[offset++] = (uint8_t)(sys->system_tick_ms >> 24);
    resp[offset++] = (uint8_t)(sys->system_tick_ms >> 16);
    resp[offset++] = (uint8_t)(sys->system_tick_ms >> 8);
    resp[offset++] = (uint8_t)(sys->system_tick_ms & 0xFF);

    sys->diagnostics.response_length = offset;
}

static void Diagnostics_ReadSensors(WiperSystem_t *sys)
{
    uint8_t *resp;
    uint16_t offset;
    uint8_t ch;

    resp = sys->diagnostics.response_data;
    offset = 0;

    /* Rain sensor */
    resp[offset++] = (uint8_t)(sys->rain_sensor.raw_value >> 8);
    resp[offset++] = (uint8_t)(sys->rain_sensor.raw_value & 0xFF);
    resp[offset++] = (uint8_t)(sys->rain_sensor.filtered_value >> 8);
    resp[offset++] = (uint8_t)(sys->rain_sensor.filtered_value & 0xFF);
    resp[offset++] = sys->rain_sensor.valid ? 1 : 0;

    /* Position and current sensors per channel */
    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        resp[offset++] = (uint8_t)(sys->position_sensor[ch].filtered_value >> 8);
        resp[offset++] = (uint8_t)(sys->position_sensor[ch].filtered_value & 0xFF);
        resp[offset++] = (uint8_t)(sys->current_sensor[ch].filtered_value >> 8);
        resp[offset++] = (uint8_t)(sys->current_sensor[ch].filtered_value & 0xFF);
    }

    /* Temperature and voltage */
    resp[offset++] = (uint8_t)(sys->temperature_sensor.filtered_value >> 8);
    resp[offset++] = (uint8_t)(sys->temperature_sensor.filtered_value & 0xFF);
    resp[offset++] = (uint8_t)(sys->voltage_sensor.filtered_value >> 8);
    resp[offset++] = (uint8_t)(sys->voltage_sensor.filtered_value & 0xFF);

    sys->diagnostics.response_length = offset;
}

static void Diagnostics_ActuatorTest(WiperSystem_t *sys)
{
    uint8_t test_type;
    uint8_t channel;
    uint16_t duration;
    uint16_t pwm_duty;

    test_type = sys->diagnostics.command_data[0];
    channel   = sys->diagnostics.command_data[1];
    duration  = ((uint16_t)sys->diagnostics.command_data[2] << 8) |
                sys->diagnostics.command_data[3];
    pwm_duty  = ((uint16_t)sys->diagnostics.command_data[4] << 8) |
                sys->diagnostics.command_data[5];

    if (channel >= WIPER_CHANNEL_COUNT && test_type < 3) {
        sys->diagnostics.response_data[0] = 0x00; /* Invalid channel */
        sys->diagnostics.response_length = 1;
        return;
    }

    switch (test_type) {
        case 0: /* Motor forward */
            Motor_SetDirection(sys, (WiperChannel_t)channel, MOTOR_DIR_FORWARD);
            Motor_SetSpeed(sys, (WiperChannel_t)channel, pwm_duty);
            break;
        case 1: /* Motor reverse */
            Motor_SetDirection(sys, (WiperChannel_t)channel, MOTOR_DIR_REVERSE);
            Motor_SetSpeed(sys, (WiperChannel_t)channel, pwm_duty);
            break;
        case 2: /* Motor stop */
            Motor_Stop(sys, (WiperChannel_t)channel);
            break;
        case 3: /* Washer pump */
            Washer_PumpOn(sys, pwm_duty);
            break;
        case 4: /* Washer pump off */
            Washer_PumpOff(sys);
            break;
        default:
            sys->diagnostics.response_data[0] = 0x00;
            sys->diagnostics.response_length = 1;
            return;
    }

    sys->diagnostics.test_active     = true;
    sys->diagnostics.test_channel    = channel;
    sys->diagnostics.test_start_time = sys->system_tick_ms;
    sys->diagnostics.test_duration_ms = duration;

    sys->diagnostics.response_data[0] = 0x01; /* Success */
    sys->diagnostics.response_length = 1;
}

static void Diagnostics_ReadConfig(WiperSystem_t *sys)
{
    uint8_t *resp;
    uint16_t offset;

    resp = sys->diagnostics.response_data;
    offset = 0;

    /* Serialize key configuration parameters */
    resp[offset++] = (uint8_t)(sys->config.speed_low.motor_pwm_duty >> 8);
    resp[offset++] = (uint8_t)(sys->config.speed_low.motor_pwm_duty & 0xFF);
    resp[offset++] = (uint8_t)(sys->config.speed_high.motor_pwm_duty >> 8);
    resp[offset++] = (uint8_t)(sys->config.speed_high.motor_pwm_duty & 0xFF);
    resp[offset++] = (uint8_t)(sys->config.wash_config.spray_duration_ms >> 8);
    resp[offset++] = (uint8_t)(sys->config.wash_config.spray_duration_ms & 0xFF);
    resp[offset++] = (uint8_t)sys->config.wash_config.wipe_count;
    resp[offset++] = (uint8_t)sys->config.auto_sensitivity;
    resp[offset++] = (uint8_t)sys->config.speed_profile;

    sys->diagnostics.response_length = offset;
}

static void Diagnostics_WriteConfig(WiperSystem_t *sys)
{
    uint8_t *data;
    uint8_t param_id;
    uint16_t value;

    data = sys->diagnostics.command_data;
    param_id = data[0];
    value = ((uint16_t)data[1] << 8) | data[2];

    switch (param_id) {
        case 0:
            sys->config.speed_low.motor_pwm_duty = Util_Clamp16(value, 100, 1000);
            break;
        case 1:
            sys->config.speed_high.motor_pwm_duty = Util_Clamp16(value, 100, 1000);
            break;
        case 2:
            sys->config.wash_config.spray_duration_ms = Util_Clamp16(value, 500, 5000);
            break;
        case 3:
            sys->config.wash_config.wipe_count = (uint16_t)Util_Clamp16(value, 1, 10);
            break;
        case 4:
            sys->config.auto_sensitivity = Util_Clamp16(value, 0, 100);
            break;
        case 5:
            if (value < SPEED_PROFILE_COUNT) {
                sys->config.speed_profile = (SpeedProfile_t)value;
            }
            break;
        case 6:
            sys->config.speed_low.ramp_up_time_ms = Util_Clamp16(value, 50, 2000);
            break;
        case 7:
            sys->config.speed_high.ramp_up_time_ms = Util_Clamp16(value, 50, 2000);
            break;
        case 8:
            sys->config.fault_config.overcurrent_threshold_ma = Util_Clamp16(value, 1000, 10000);
            break;
        case 9:
            sys->config.fault_config.stall_timeout_ms = Util_Clamp16(value, 1000, 10000);
            break;
        default:
            sys->diagnostics.response_data[0] = 0x00; /* Invalid param */
            sys->diagnostics.response_length = 1;
            return;
    }

    sys->diagnostics.response_data[0] = 0x01; /* Success */
    sys->diagnostics.response_length = 1;
}

/*=============================================================================
 * SECTION 23: STATISTICS TRACKING
 *===========================================================================*/

static void Statistics_Update(WiperSystem_t *sys)
{
    uint32_t elapsed;
    uint8_t ch;

    if (sys == NULL) {
        return;
    }

    elapsed = Util_ElapsedTime(sys->last_stats_update_time, sys->system_tick_ms);

    if (elapsed >= 1000) {
        sys->statistics.total_runtime_sec++;

        for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
            if (sys->motor[ch].is_running) {
                sys->statistics.motor_on_time_sec++;
            }
        }

        sys->last_stats_update_time = sys->system_tick_ms;
    }
}

/*=============================================================================
 * SECTION 24: MAIN TASK FUNCTIONS
 *===========================================================================*/

static void Task_MainControl(WiperSystem_t *sys)
{
    uint8_t ch;

    if (sys == NULL || !sys->system_initialized) {
        return;
    }

    /* Process user inputs */
    Input_ProcessAll(sys);

    /* Run state machines for each wiper channel */
    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        StateMachine_Process(sys, (WiperChannel_t)ch);
    }

    /* Process fault detection */
    Fault_ProcessAll(sys);
}

static void Task_SensorProcessing(WiperSystem_t *sys)
{
    if (sys == NULL || !sys->system_initialized) {
        return;
    }

    Sensor_ReadAll(sys);
}

static void Task_Diagnostics(WiperSystem_t *sys)
{
    if (sys == NULL || !sys->system_initialized) {
        return;
    }

    Diagnostics_Process(sys);
}

static void Task_Statistics(WiperSystem_t *sys)
{
    if (sys == NULL || !sys->system_initialized) {
        return;
    }

    Statistics_Update(sys);
}

/*=============================================================================
 * SECTION 25: REAL-TIME SCHEDULER
 *===========================================================================*/

static void Scheduler_Run(WiperSystem_t *sys)
{
    uint32_t current_time;
    uint32_t elapsed;

    if (sys == NULL || !sys->system_initialized) {
        return;
    }

    current_time = HAL_GetTick();
    sys->system_tick_ms = current_time;

    /* Main control task - highest frequency */
    elapsed = Util_ElapsedTime(sys->last_main_task_time, current_time);
    if (elapsed >= sys->config.main_task_period_ms) {
        Task_MainControl(sys);
        sys->last_main_task_time = current_time;
    }

    /* Sensor processing task */
    elapsed = Util_ElapsedTime(sys->last_sensor_task_time, current_time);
    if (elapsed >= sys->config.sensor_task_period_ms) {
        Task_SensorProcessing(sys);
        sys->last_sensor_task_time = current_time;
    }

    /* Diagnostics task - lowest frequency */
    elapsed = Util_ElapsedTime(sys->last_diag_task_time, current_time);
    if (elapsed >= sys->config.diagnostic_task_period_ms) {
        Task_Diagnostics(sys);
        Task_Statistics(sys);
        sys->last_diag_task_time = current_time;
    }

    /* Reset watchdog */
    HAL_WatchdogReset();
}

/*=============================================================================
 * SECTION 26: EXTERNAL API FUNCTIONS
 *===========================================================================*/

/**
 * @brief Set the wiper mode externally (e.g., from CAN bus or body controller)
 */
void WiperCtrl_SetMode(WiperMode_t mode)
{
    if (mode < WIPER_MODE_COUNT) {
        HAL_EnterCritical();
        g_wiper_system.runtime[WIPER_FRONT].requested_mode = mode;
        HAL_ExitCritical();
    }
}

/**
 * @brief Get the current wiper mode
 */
WiperMode_t WiperCtrl_GetMode(void)
{
    return g_wiper_system.runtime[WIPER_FRONT].current_mode;
}

/**
 * @brief Get the current wiper state
 */
WiperState_t WiperCtrl_GetState(void)
{
    return g_wiper_system.runtime[WIPER_FRONT].current_state;
}

/**
 * @brief Get current active faults
 */
uint16_t WiperCtrl_GetActiveFaults(void)
{
    return g_wiper_system.fault_mgr.active_faults;
}

/**
 * @brief Get current rain intensity
 */
RainIntensity_t WiperCtrl_GetRainIntensity(void)
{
    return g_wiper_system.runtime[WIPER_FRONT].rain_intensity;
}

/**
 * @brief Set vehicle speed (called from vehicle CAN bus handler)
 */
void WiperCtrl_SetVehicleSpeed(uint16_t speed_kmh)
{
    HAL_EnterCritical();
    g_wiper_system.runtime[WIPER_FRONT].vehicle_speed_kmh = speed_kmh;
    g_wiper_system.runtime[WIPER_REAR].vehicle_speed_kmh  = speed_kmh;
    HAL_ExitCritical();
}

/**
 * @brief Set ignition state (called from body controller)
 */
void WiperCtrl_SetIgnition(bool state)
{
    HAL_EnterCritical();
    g_wiper_system.runtime[WIPER_FRONT].ignition_active = state;
    g_wiper_system.runtime[WIPER_REAR].ignition_active  = state;
    HAL_ExitCritical();
}

/**
 * @brief Set intermittent level (1-6)
 */
void WiperCtrl_SetIntermittentLevel(uint8_t level)
{
    if (level >= 1 && level <= 6) {
        HAL_EnterCritical();
        g_wiper_system.runtime[WIPER_FRONT].intermittent_level = level;
        HAL_ExitCritical();
    }
}

/**
 * @brief Set auto sensitivity (0-100)
 */
void WiperCtrl_SetAutoSensitivity(uint16_t sensitivity)
{
    HAL_EnterCritical();
    g_wiper_system.config.auto_sensitivity = Util_Clamp16(sensitivity, 0, 100);
    HAL_ExitCritical();
}

/**
 * @brief Submit a diagnostic command
 */
bool WiperCtrl_SubmitDiagCommand(DiagCommand_t cmd, const uint8_t *data,
                                  uint8_t data_len)
{
    if (cmd >= DIAG_CMD_COUNT) {
        return false;
    }

    if (!g_wiper_system.diagnostics.command_complete) {
        return false; /* Previous command still pending */
    }

    HAL_EnterCritical();
    g_wiper_system.diagnostics.pending_command = cmd;
    g_wiper_system.diagnostics.command_complete = false;

    if (data != NULL && data_len > 0) {
        if (data_len > sizeof(g_wiper_system.diagnostics.command_data)) {
            data_len = sizeof(g_wiper_system.diagnostics.command_data);
        }
        memcpy(g_wiper_system.diagnostics.command_data, data, data_len);
    }
    HAL_ExitCritical();

    return true;
}

/**
 * @brief Check if diagnostic response is ready
 */
bool WiperCtrl_IsDiagComplete(void)
{
    return g_wiper_system.diagnostics.command_complete;
}

/**
 * @brief Get diagnostic response data
 */
uint16_t WiperCtrl_GetDiagResponse(uint8_t *buffer, uint16_t buffer_size)
{
    uint16_t copy_len;

    if (buffer == NULL || buffer_size == 0) {
        return 0;
    }

    if (!g_wiper_system.diagnostics.command_complete) {
        return 0;
    }

    copy_len = g_wiper_system.diagnostics.response_length;
    if (copy_len > buffer_size) {
        copy_len = buffer_size;
    }

    memcpy(buffer, g_wiper_system.diagnostics.response_data, copy_len);
    return copy_len;
}

/**
 * @brief Get system statistics
 */
void WiperCtrl_GetStatistics(WiperStatistics_t *stats)
{
    if (stats != NULL) {
        HAL_EnterCritical();
        memcpy(stats, &g_wiper_system.statistics, sizeof(WiperStatistics_t));
        HAL_ExitCritical();
    }
}

/**
 * @brief Get motor position for specified channel (0-4095)
 */
uint16_t WiperCtrl_GetPosition(WiperChannel_t ch)
{
    if (ch < WIPER_CHANNEL_COUNT) {
        return g_wiper_system.position_sensor[ch].filtered_value;
    }
    return 0;
}

/**
 * @brief Check if system is in fault state
 */
bool WiperCtrl_IsInFault(void)
{
    return (g_wiper_system.runtime[WIPER_FRONT].current_state == WIPER_STATE_FAULT);
}

/**
 * @brief Get motor current in milliamps (approximate)
 */
uint16_t WiperCtrl_GetMotorCurrent(WiperChannel_t ch)
{
    uint16_t current_ma;

    if (ch >= WIPER_CHANNEL_COUNT) {
        return 0;
    }

    current_ma = (uint16_t)Util_Map(
        (int32_t)g_wiper_system.current_sensor[ch].filtered_value,
        0, 4095, 0, 10000);

    return current_ma;
}

/*=============================================================================
 * SECTION 27: POWER MANAGEMENT
 *===========================================================================*/

typedef enum {
    POWER_MODE_NORMAL = 0,
    POWER_MODE_LOW_POWER,
    POWER_MODE_SLEEP
} PowerMode_t;

static PowerMode_t g_power_mode = POWER_MODE_NORMAL;

static void PowerManagement_Process(WiperSystem_t *sys)
{
    bool any_active;
    uint8_t ch;

    if (sys == NULL) {
        return;
    }

    any_active = false;
    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        if (sys->runtime[ch].current_mode != WIPER_MODE_OFF ||
            sys->runtime[ch].current_state != WIPER_STATE_IDLE) {
            any_active = true;
            break;
        }
    }

    if (!sys->runtime[WIPER_FRONT].ignition_active && !any_active) {
        /* No ignition, no active wiper operation */
        if (g_power_mode == POWER_MODE_NORMAL) {
            g_power_mode = POWER_MODE_LOW_POWER;
            /* Reduce sensor sampling rate */
            /* Disable unused ADC channels */
            /* Reduce main task frequency */
        }
    } else {
        if (g_power_mode != POWER_MODE_NORMAL) {
            g_power_mode = POWER_MODE_NORMAL;
            /* Restore normal operation */
        }
    }
}

/*=============================================================================
 * SECTION 28: CAN BUS INTERFACE (STUB)
 *===========================================================================*/

typedef struct {
    uint32_t id;
    uint8_t  data[8];
    uint8_t  dlc;
} CAN_Message_t;

static void CAN_ProcessRxMessage(WiperSystem_t *sys, const CAN_Message_t *msg)
{
    if (sys == NULL || msg == NULL) {
        return;
    }

    /* Process incoming CAN messages */
    switch (msg->id) {
        case 0x200: /* Vehicle speed message */
            if (msg->dlc >= 2) {
                uint16_t speed = ((uint16_t)msg->data[0] << 8) | msg->data[1];
                WiperCtrl_SetVehicleSpeed(speed);
            }
            break;

        case 0x201: /* Ignition status */
            if (msg->dlc >= 1) {
                WiperCtrl_SetIgnition(msg->data[0] != 0);
            }
            break;

        case 0x300: /* Wiper control command from BCM */
            if (msg->dlc >= 2) {
                WiperCtrl_SetMode((WiperMode_t)msg->data[0]);
                if (msg->data[1] > 0) {
                    WiperCtrl_SetIntermittentLevel(msg->data[1]);
                }
            }
            break;

        case 0x7DF: /* Diagnostic request (OBD) */
        case 0x710: /* Diagnostic request (UDS) */
            if (msg->dlc >= 3) {
                DiagCommand_t cmd = (DiagCommand_t)msg->data[0];
                WiperCtrl_SubmitDiagCommand(cmd, &msg->data[1], msg->dlc - 1);
            }
            break;

        default:
            break;
    }
}

static void CAN_TransmitStatus(WiperSystem_t *sys)
{
    CAN_Message_t tx_msg;

    if (sys == NULL) {
        return;
    }

    /* Wiper status message */
    tx_msg.id  = 0x400;
    tx_msg.dlc = 8;
    tx_msg.data[0] = (uint8_t)sys->runtime[WIPER_FRONT].current_mode;
    tx_msg.data[1] = (uint8_t)sys->runtime[WIPER_FRONT].current_state;
    tx_msg.data[2] = (uint8_t)sys->runtime[WIPER_FRONT].rain_intensity;
    tx_msg.data[3] = (uint8_t)(sys->fault_mgr.active_faults >> 8);
    tx_msg.data[4] = (uint8_t)(sys->fault_mgr.active_faults & 0xFF);
    tx_msg.data[5] = sys->runtime[WIPER_FRONT].intermittent_level;
    tx_msg.data[6] = (uint8_t)(sys->runtime[WIPER_FRONT].current_position >> 4);
    tx_msg.data[7] = (uint8_t)sys->runtime[WIPER_REAR].current_state;

    /* In real implementation, call CAN driver to transmit */
    (void)tx_msg;
}

/*=============================================================================
 * SECTION 29: NVM (NON-VOLATILE MEMORY) INTERFACE
 *===========================================================================*/

#define NVM_CONFIG_ADDRESS   0x0800F000
#define NVM_STATS_ADDRESS    0x0800F400
#define NVM_MAGIC_NUMBER     0xA5B6C7D8

typedef struct {
    uint32_t         magic;
    uint32_t         checksum;
    WiperConfig_t    config;
    WiperStatistics_t statistics;
} NVM_Data_t;

static uint32_t NVM_CalculateChecksum(const uint8_t *data, uint32_t length)
{
    uint32_t checksum = 0;
    uint32_t i;

    for (i = 0; i < length; i++) {
        checksum += data[i];
        checksum = (checksum << 1) | (checksum >> 31); /* Rotate left */
    }

    return checksum;
}

static bool NVM_SaveConfig(WiperSystem_t *sys)
{
    NVM_Data_t nvm_data;

    if (sys == NULL) {
        return false;
    }

    nvm_data.magic = NVM_MAGIC_NUMBER;
    memcpy(&nvm_data.config, &sys->config, sizeof(WiperConfig_t));
    memcpy(&nvm_data.statistics, &sys->statistics, sizeof(WiperStatistics_t));
    nvm_data.checksum = NVM_CalculateChecksum(
        (const uint8_t *)&nvm_data.config,
        sizeof(WiperConfig_t) + sizeof(WiperStatistics_t));

    /* In real implementation: erase flash sector, write data */
    (void)nvm_data;

    return true;
}

static bool NVM_LoadConfig(WiperSystem_t *sys)
{
    NVM_Data_t nvm_data;
    uint32_t calc_checksum;

    if (sys == NULL) {
        return false;
    }

    /* In real implementation: read from flash */
    memset(&nvm_data, 0, sizeof(NVM_Data_t));

    /* Verify magic number */
    if (nvm_data.magic != NVM_MAGIC_NUMBER) {
        return false;
    }

    /* Verify checksum */
    calc_checksum = NVM_CalculateChecksum(
        (const uint8_t *)&nvm_data.config,
        sizeof(WiperConfig_t) + sizeof(WiperStatistics_t));

    if (calc_checksum != nvm_data.checksum) {
        return false;
    }

    memcpy(&sys->config, &nvm_data.config, sizeof(WiperConfig_t));
    memcpy(&sys->statistics, &nvm_data.statistics, sizeof(WiperStatistics_t));

    return true;
}

/*=============================================================================
 * SECTION 30: SELF-TEST AT STARTUP
 *===========================================================================*/

typedef enum {
    SELF_TEST_PASS = 0,
    SELF_TEST_FAIL_ADC,
    SELF_TEST_FAIL_GPIO,
    SELF_TEST_FAIL_PWM,
    SELF_TEST_FAIL_MOTOR,
    SELF_TEST_FAIL_SENSOR,
    SELF_TEST_FAIL_NVM
} SelfTestResult_t;

static SelfTestResult_t SelfTest_Run(WiperSystem_t *sys)
{
    uint16_t adc_val;
    uint8_t ch;

    if (sys == NULL) {
        return SELF_TEST_FAIL_ADC;
    }

    /* Test ADC channels - verify non-zero reads */
    for (ch = 0; ch <= ADC_CH_VOLTAGE; ch++) {
        adc_val = HAL_ADC_Read(ch);
        /* Basic sanity check - ADC should not be stuck at 0 or max */
        /* In real hardware, this would be more thorough */
        (void)adc_val;
    }

    /* Test GPIO - verify park switch can be read */
    (void)HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_PARK_SW_A);
    (void)HAL_GPIO_ReadPin(GPIO_PORT_INPUT, GPIO_PIN_PARK_SW_B);

    /* Test PWM - set and verify duty cycle */
    HAL_PWM_SetDuty(PWM_CH_MOTOR_A, 0);
    HAL_PWM_SetDuty(PWM_CH_MOTOR_B, 0);

    /* Test motor briefly */
    Motor_SetDirection(sys, WIPER_FRONT, MOTOR_DIR_FORWARD);
    Motor_SetSpeed(sys, WIPER_FRONT, 200);
    HAL_DelayMs(100);

    /* Read current to verify motor is responding */
    Sensor_ReadCurrent(sys, WIPER_FRONT);

    Motor_Stop(sys, WIPER_FRONT);
    HAL_DelayMs(50);

    /* Repeat for rear */
    Motor_SetDirection(sys, WIPER_REAR, MOTOR_DIR_FORWARD);
    Motor_SetSpeed(sys, WIPER_REAR, 200);
    HAL_DelayMs(100);

    Sensor_ReadCurrent(sys, WIPER_REAR);

    Motor_Stop(sys, WIPER_REAR);
    HAL_DelayMs(50);

    /* Verify position sensors are providing reasonable values */
    for (ch = 0; ch < WIPER_CHANNEL_COUNT; ch++) {
        Sensor_ReadPosition(sys, (WiperChannel_t)ch);
        if (!sys->position_sensor[ch].valid) {
            return SELF_TEST_FAIL_SENSOR;
        }
    }

    return SELF_TEST_PASS;
}

/*=============================================================================
 * SECTION 31: MAIN FUNCTION
 *===========================================================================*/

int main(void)
{
    SelfTestResult_t test_result;

    /* Initialize the wiper controller system */
    System_Init(&g_wiper_system);

    /* Attempt to load saved configuration from NVM */
    if (!NVM_LoadConfig(&g_wiper_system)) {
        /* Load defaults if NVM is empty or corrupt */
        Config_LoadDefaults(&g_wiper_system.config);
    }

    /* Run startup self-test */
    test_result = SelfTest_Run(&g_wiper_system);
    if (test_result != SELF_TEST_PASS) {
        g_wiper_system.system_error_code = (uint8_t)test_result;
        /* Set fault but continue operation - degrade gracefully */
        if (test_result == SELF_TEST_FAIL_MOTOR) {
            Fault_SetFault(&g_wiper_system, FAULT_MOTOR_STALL);
        } else if (test_result == SELF_TEST_FAIL_SENSOR) {
            Fault_SetFault(&g_wiper_system, FAULT_POSITION_SENSOR);
        }
    }

    /* Signal successful initialization */
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, true);
    HAL_DelayMs(500);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, false);
    HAL_DelayMs(500);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, true);
    HAL_DelayMs(500);
    HAL_GPIO_WritePin(GPIO_PORT_MOTOR, GPIO_PIN_STATUS_LED, false);

    /* Main real-time loop */
    while (1) {
        /* Run the cooperative scheduler */
        Scheduler_Run(&g_wiper_system);

        /* Power management */
        PowerManagement_Process(&g_wiper_system);

        /* Periodic CAN status transmission (every 100ms) */
        if ((g_wiper_system.system_tick_ms % 100) == 0) {
            CAN_TransmitStatus(&g_wiper_system);
        }

        /* Periodic NVM save (every 60 seconds if data changed) */
        if ((g_wiper_system.system_tick_ms % 60000) == 0) {
            NVM_SaveConfig(&g_wiper_system);
        }
    }

    /* Should never reach here */
    return 0;
}

/*=============================================================================
 * END OF FILE
 *===========================================================================*/