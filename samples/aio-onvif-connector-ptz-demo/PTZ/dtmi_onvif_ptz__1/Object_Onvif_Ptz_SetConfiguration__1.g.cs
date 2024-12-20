/* Code generated by Azure.Iot.Operations.ProtocolCompiler; DO NOT EDIT. */

#nullable enable

namespace PTZ.dtmi_onvif_ptz__1
{
    using System;
    using System.Collections.Generic;
    using System.Text.Json.Serialization;
    using PTZ;

    public class Object_Onvif_Ptz_SetConfiguration__1
    {
        /// <summary>
        /// Flag that makes configuration persistent. Example: User wants the configuration to exist after reboot.
        /// </summary>
        [JsonPropertyName("ForcePersistence")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public bool? ForcePersistence { get; set; } = default;

        /// <summary>
        /// The 'PTZConfiguration' Field.
        /// </summary>
        [JsonPropertyName("PTZConfiguration")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public Object_Onvif_Ptz_PTZConfiguration__1? PTZConfiguration { get; set; } = default;

    }
}
