import csv
import matplotlib.pyplot as plt
import numpy as np

# Raw data as a string
data = """
TYPE LEN WID TOTAL SIZE AREA
dpram 64 8 512 156x131 20436
sp 64 28 1792 275x89 24475
dpram 256 4 1024 102x280 28560
dpram 256 8 2048 156x280 43680
dpram 256 8 2048 156x280 43680
dpram 512 4 2048 156x280 43680
sp 256 18 4608 323x137 44251
dpram 128 16 2048 264x181 47784
dpram 64 24 1536 372x131 48732
dpram 32 32 1024 480x106 50880
spram 64 64 4096 578x89 51442
dpram 64 32 2048 480x131 62880
dpram 32 40 1280 607x108 65556
SP 256 36 9216 342x210 71820
dpram 512 8 4096 264x280 73920
dpram 512 8 4096 264x280 73920
DP 128 32 4096 480x181 86880
dpram 32 64 2048 931x108 100548
sp 256 62 15872 562x210 118020
dpram 64 64 4096 931x133 123823
dpram 1024 8 8192 264x479 126456
sp 256 70 17920 629x210 132090
DP 256 32 8192 480x280 134400
dpram 256 32 8192 480x280 134400
dpram 512 16 8192 480x280 134400
dpram 128 64 8192 931x183 170373
spram 512 50 25600 828x218 180504
spram 512 50 25600 828x218 180504
spram 1024 32 32768 544x380 206720
sp 2048 18 36864 588x374 219912
dpram 1024 16 16384 480x479 229920
SP 1024 36 36864 607x380 230660
DP 512 32 16384 499x481 240019
dpram 2048 8 16384 499x481 240019
dpram 256 64 16384 931x282 262542
spram 4096 16 65536 1015x375 380625
SP 2048 36 73728 1137x373 424101
dpram 1024 32 32768 499x879 438621
dpram 4096 8 32768 499x879 438621
dpram 2048 16 32768 931x481 447811
dpram 512 64 32768 931x481 447811
dpram 2048 24 49152 715x879 628485
spram 4096 32 131072 1015x698 708470
sp 2048 62 126976 1018x704 716672
dpram 4096 14 57344 823x879 723417
sp 2048 70 143360 1144x704 805376
dpram 1024 64 65536 931x879 818349
dpram 2048 32 65536 931x879 818349
dpram 4096 16 65536 931x879 818349
dpram 4096 4 16384 931x879 818349
dpram 1024 68 69632 986x879 866694
dpram 4096 24 98304 1364x879 1198956
dpram 2048 64 131072 1797x879 1579563
dpram 4096 32 131072 1797x879 1579563
"""

# Parse the data into rows
lines = data.strip().split("\n")
header = ["TYPE", "LEN", "WID", "TOTAL", "SIZE", "AREA"]  # Explicit column titles
rows = [line.split() for line in lines[1:]]

# Write to a CSV file
output_file = "/home/barak/sram_data.csv"
with open(output_file, "w", newline="") as csvfile:
    writer = csv.writer(csvfile)
    writer.writerow(header)  # Write the header
    writer.writerows(rows)   # Write the data rows

print(f"Data has been organized and saved to {output_file}")

# Extract TOTAL and AREA columns for plotting with type information
dpram_total = []
dpram_area = []
spram_total = []
spram_area = []

for row in rows:
    mem_type = row[0].lower()  # Convert to lowercase for comparison
    total = int(row[3])
    area = int(row[5])
    
    if mem_type in ['dpram', 'dp']:
        dpram_total.append(total)
        dpram_area.append(area)
    elif mem_type in ['spram', 'sp']:
        spram_total.append(total)
        spram_area.append(area)

# Create scatter plot with different colors
plt.figure(figsize=(12, 8))
plt.scatter(dpram_total, dpram_area, alpha=0.7, color='red', label='DPRAM/DP')
plt.scatter(spram_total, spram_area, alpha=0.7, color='blue', label='SPRAM/SP')

# Add trend lines with gradients
if len(dpram_total) > 1:
    z_dpram = np.polyfit(dpram_total, dpram_area, 1)
    p_dpram = np.poly1d(z_dpram)
    plt.plot(sorted(dpram_total), p_dpram(sorted(dpram_total)), "r--", alpha=0.8, 
             label=f'DPRAM trend (m={z_dpram[0]:.2f})')

if len(spram_total) > 1:
    z_spram = np.polyfit(spram_total, spram_area, 1)
    p_spram = np.poly1d(z_spram)
    plt.plot(sorted(spram_total), p_spram(sorted(spram_total)), "b--", alpha=0.8, 
             label=f'SPRAM trend (m={z_spram[0]:.2f})')

plt.xlabel('TOTAL')
plt.ylabel('AREA')
plt.title('SRAM Data: TOTAL vs AREA')
plt.legend()
plt.grid(True, alpha=0.3)
plt.savefig("sram_total_vs_area.png")  # Save the figure as a PNG file
plt.show()
