/*
 * Helper class for comparisson and distance functions
 *
 * @author: Iskander Mukhamedgaliyev
 */
public with sharing class ClusterDataHelper {
    public class NumericFieldFunctions implements ClusterFieldFunctions {
        public Integer compare(Object compare, Object compareTo) {
            Integer result = 0;
            if (compare instanceof Integer) {
                if ((Integer)compare == (Integer)compareTo) result = 0;
                else if ((Integer)compare > (Integer)compareTo) result = 1;
                else result = -1;
            } else if (compare instanceof Long) {
                if ((Long)compare == (Long)compareTo) result = 0;
                else if ((Long)compare > (Long)compareTo) result = 1;
                else result = -1;
                
            } else if (compare instanceof Decimal) {
                if ((Decimal)compare == (Decimal)compareTo) result = 0;
                else if ((Decimal)compare > (Decimal)compareTo) result = 1;
                else result = -1;
                
            } else if (compare instanceof Double) {
                if (Math.abs((Double)compare - (Double)compareTo) < DOUBLEEPSILON) result = 0;
                else if ((Double)compare > (Double)compareTo) result = 1;
                else result = -1;
                
            } else {
                throw new ClusterException('Datatype is not supported for value ' + String.valueOf(compare));
            }
            return result;
        }        
    }

    public class TextFieldFunctions implements ClusterFieldFunctions {
        public Integer compare(Object compare, Object compareTo) {
            //We will use specific compare for strings because we need max length to normalize distance
            Integer result;
            String s1 = String.valueOf(compare);
            String s2 = String.valueOf(compareTo);
            if (s1.length() > s2.length()) result = 1;
            else if (s1.length() < s2.length()) result = -1;
            else result = s1.compareTo(s2);
            return result;
        }        
    }

    public class CategoryFieldFunctions implements ClusterFieldFunctions{
        public Integer compare(Object compare, Object compareTo) {
            return String.valueOf(compare).compareTo(String.valueOf(compareTo));
        }        
    }

    private static Logger log = LogFactory.getLogger();
    private static final Map<String, ClusterFieldFunctions> fieldFunctionsMap;
    public static final Double DOUBLEEPSILON = 0.000001;
    public static final Double DOUBLE_MAX_VALUE = 9223372036854775807.0;

    static {
        fieldFunctionsMap = new Map<String, ClusterFieldFunctions>();
        fieldFunctionsMap.put(ClusterConstants.FIELDTYPE_NUMERIC, new NumericFieldFunctions());
        fieldFunctionsMap.put(ClusterConstants.FIELDTYPE_TEXT, new TextFieldFunctions());
        fieldFunctionsMap.put(ClusterConstants.FIELDTYPE_CATEGORY, new CategoryFieldFunctions());
    }

    public static Object getSObjectFieldValue(SObject record, ClusterModelFieldWrapper field){
        Object value;
        if (field.relationName != null && field.relationName != '') {
            SObject relation = record.getSObject(field.relationName);
            value = relation == null ? null : relation.get(field.name);
        }
        else {
            value = record.get(field.name);
        }
        if (value instanceof DateTime) {
            value = ((DateTime)value).getTime();  //Convert datetime to number for calculations
        }
        return value;
    }

    public static Integer compareFieldValueAbs(Object compare, Object compareTo, ClusterModelFieldWrapper field){
        Integer result = 0;
        if ((compare == null) && (compareTo == null)) result = 0;
        else if (compare == null) result = -1;
        else if (compareTo == null) result = 1;
        else {
            ClusterFieldFunctions fieldFunctions = fieldFunctionsMap.get(field.distanceType);
            if (fieldFunctions != null) result = fieldFunctions.compare(compare, compareTo);
            else result = 0;
        }
        return result;
    }

    public static void normalizeObject(Object[] currentObject, ClusterJobState jobState) {
        //TODO: implement
    }

    public static Double calculateMeanDistanceToCluster(ClusterDataPoint sourceDataPoint, Integer clusterIndex, ClusterAlgorithmRunner runner) {
        ClusterKMeansJobState jobState = (ClusterKMeansJobState)runner.getJobState();
        Integer currentClusterSize = 0;
        Double currentClusterDistance = 0;
        for (ClusterDataPoint dataPoint:jobState.dataPoints) {
            if (clusterIndex == dataPoint.clusterIndex && dataPoint.recordId != sourceDataPoint.recordId) {
                currentClusterSize++;
                currentClusterDistance += runner.calculateDistance(sourceDataPoint.values, dataPoint.values);
            }
        }
        currentClusterDistance = (currentClusterSize > 0) ? currentClusterDistance / currentClusterSize : 0;
        return currentClusterDistance;
    }

    public static Integer findNearestCluster(ClusterDataPoint dataPoint, ClusterAlgorithmRunner runner) {
        ClusterKMeansJobState jobState = (ClusterKMeansJobState)runner.getJobState();
        //Find nearest cluster
        Double minDistance = DOUBLE_MAX_VALUE;
        Integer nearestClusterIndex = -1;
        for (Integer i = 0; i < jobState.centroids.size(); i++) {
            Double currentDistance = runner.calculateDistance(dataPoint.values, jobState.centroids[i].values);
            if ((currentDistance < minDistance) && (dataPoint.clusterIndex != i)) {
                minDistance = currentDistance;
                nearestClusterIndex = i;
            }
        }
        return nearestClusterIndex;
    }

    public static Double calculateNumericGowerDistance(Double a, Double b, Double delta) {
        if (a == null && b == null) {
            return 0;
        }
        Double d = 0;
        try {
            d = Math.abs(a - b) / delta;
        }
        catch (Exception ex) {
            log.error('Exception in calculateNumericGowerDistance', ex);
            d = 1; //Set maximum distance value in case of exception
        }
        return d;
    }

    public static Double calculateTextGowerDistance(String a, String b, Integer min, Integer max) {
        if (a == null && b == null) return 0;
        Double r = max;
        Double d = 0;
        try {
            if (a == null) {
                d = Double.valueOf(b.length()) / r;
            }
            else if (b == null) {
                d = Double.valueOf(a.length()) / r;
            }
            else {
                d = Double.valueOf(a.getLevenshteinDistance(b)) / r;
            }
        }
        catch (Exception ex) {
            log.error('Exception in calculateTextGowerDistance', ex);
            d = 1; //Set maximum distance value in case of exception
        }
        return d;
    }

    public static Double calculateCategoryGowerDistance(String a, String b) {
        if (a == null && b == null) {
            return 0;
        }
        return (a == b) ? 0 : 1;
    }

    public static Double calculateGowerDistance(Object[] currentObject, Object[] centroid, ClusterJobState jobState) {
        Double distance = 0;
        Double weight = 0;
        ClusterModelWrapper model = jobState.model;
        ClusterModelFieldWrapper modelField;
        for (Integer i = 0; i < model.fields.size(); i++) {
            modelField = model.fields[i];
            if (modelField.isNumeric) {
                distance += modelField.weight * calculateNumericGowerDistance(Double.valueOf(currentObject[i]), Double.valueOf(centroid[i]), 
                    jobState.minMaxValues[i].delta);
                weight += modelField.weight;
            }
            else if (modelField.isText) {
                distance += modelField.weight * calculateTextGowerDistance(String.valueOf(currentObject[i]), String.valueOf(centroid[i]), 
                    Integer.valueOf(jobState.minMaxValues[i].minValue), Integer.valueOf(jobState.minMaxValues[i].maxValue));
                weight += modelField.weight;
            }
            else if (modelField.isCategory) {
                distance += modelField.weight * calculateCategoryGowerDistance(String.valueOf(currentObject[i]), String.valueOf(centroid[i]));
                weight += modelField.weight;
            }
        }
        return distance / weight;
    }

    public static Double calculateEuclideanDistance(Object[] currentObject, Object[] centroid, ClusterJobState jobState) {
        Double sumDistance = 0;
        ClusterModelWrapper model = jobState.model;
        for (Integer i = 0; i < model.fields.size(); i++) {
            if (model.fields[i].isNumeric) {
                try {
                    Double distance = model.fields[i].weight *  ClusterDataHelper.calculateNumericGowerDistance(Double.valueOf(currentObject[i]), Double.valueOf(centroid[i]), jobState.minMaxValues[i].delta);
                    sumDistance += distance * distance;
                }
                catch (Exception ex) 
                {
                    log.error('Exception in calculateEuclideanDistance', ex);
                    // Let's just log and swallow null values or division by zero for now
                } 
            }
        }
        return Math.sqrt(sumDistance);
    }

    public static Double calculateManhattanDistance(Object[] currentObject, Object[] centroid, ClusterJobState jobState) {
        //Numeric part of Gower distance uses Manhattan algorithm
        return calculateGowerDistance(currentObject, centroid, jobState);
    }

    public static Integer getRandomInt(Integer min, Integer max) {
        return Math.round(Math.random() * (max - min) + min);
    }

    public static void populateRandomDataPoints(Integer count, ClusterKMeansJobState jobState) {
        ClusterAccessCheck.checkReadPermission(Schema.SObjectType.ClusterJobResult__c);
        //isAccessible permission is checked in ClusterAccessCheck.checkReadPermission, exception is thrown in case of no access
        List<ClusterJobResult__c> randomRecords = [SELECT Id, Cluster__c, Json__c, RecordId__c, RecordName__c, ClusterNumber__c, ClusterJob__c FROM ClusterJobResult__c WHERE ClusterJob__c = :jobState.clusterJob.Id ORDER BY Random__c LIMIT :count];
        Integer index=0;
        List<ClusterDataPoint> dataPoints = new List<ClusterDataPoint>();
        for (ClusterJobResult__c record:randomRecords){
            jobState.sampleResultsIds.add(record.Id);
            ClusterDataPoint dp = new ClusterDataPoint(record);
            dataPoints.add(dp);
            jobState.dataPointsIdMap.put(dp.recordId, index);
            index++;
        }
        jobState.dataPoints = dataPoints;
    }

    public static Boolean doublesEqual(Double a, Double b) {
        return Math.abs(a-b) < DOUBLEEPSILON;
    }
}
